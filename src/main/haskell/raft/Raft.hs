module Raft ( Actor (..), init ) where

import           InputOutput             ( TimeoutMs, Timer (..), withTimeout, timerThread )
import           Net                     ( send )
import           Control.Concurrent      ( ThreadId, killThread )
import           Control.Concurrent.MVar ( MVar, newMVar, takeMVar, putMVar )
import           Control.Monad.State     ( StateT, runStateT, get, put )
import           Control.Monad.Trans     ( lift )
import qualified Data.Set                as Set
import           Network.Socket          ( Socket, SockAddr, recvFrom )
import           System.Random           ( randomRIO )
import           Prelude                 hiding ( log, init )

------------------------------------------------

data Role               = Leader
                        | Follower
                        | Candidate

type Term               = Integer

newtype Address         = Address { addr_to_string :: String }
                        deriving (Show, Read, Eq, Ord)

data Actor              = Actor { actor_addr :: SockAddr }
                        deriving (Show, Eq)

data ServerState        = ServerState { state_self   :: Actor
                                      , state_peers  :: [Actor]
                                      , state_ssock  :: Socket
                                      , state_rsock  :: Socket
                                      , state_role   :: Role
                                      , state_term   :: Term
                                      , state_squeue :: MVar [String]
                                      , state_stimer :: MVar Timer
                                      , state_sthr   :: Maybe ThreadId
                                      , state_leader :: Maybe Address
                                      }

data Message            = AppendEntries Address Term [String]
                        | RequestVote   Address Term
                        | CastVote      Address Term
                        | Timeout       Address
                        deriving (Show, Read)

type ApplicationContext = StateT ServerState IO

------------------------------------------------

init :: Actor -> [Actor] -> Socket -> Socket -> IO ()
init self peers ssock rsock = do
  squeue <- newMVar []
  stimer <- newMVar $ Timer broadcastTimeout 0 (return ())
  runStateT (become Follower)
            (ServerState self peers ssock rsock Follower 0 squeue stimer Nothing Nothing)
  return ()

become :: Role -> ApplicationContext ()
become Follower = do
  log "I am follower"
  setRole Follower
  handleMessagesAsFollower

become Candidate = do
  newTerm
  setRole Candidate
  ctx <- get
  let self = state_self ctx
  let selfAddr = actor_addr self
  let term = state_term ctx
  log "I am candidate"
  broadcast $ RequestVote (saddr2addr selfAddr) term
  handleMessagesAsCandidate Set.empty

become Leader = do
  log "I am leader"
  setRole Leader
  installSenderThread
  handleMessagesAsLeader

unbecome Leader = do
  uninstallSenderThread

handleMessagesAsFollower = do
  ctx <- get
  let self = state_self ctx
  message <- awaitMessage electionTimeout
  case message of
    Timeout sender | sender == saddr2addr (actor_addr self) -> become Candidate
    AppendEntries sender term entries | term >= state_term ctx -> do
      append entries
      if term > state_term ctx
      then setTerm term
      else return ()
      ctx <- get
      put $ ctx { state_leader = Just sender }
      handleMessagesAsFollower
    RequestVote sender term | term > state_term ctx -> do
      setTerm term
      castVote sender
      handleMessagesAsFollower
    otherwise -> handleMessagesAsFollower

handleMessagesAsCandidate votes = do
  ctx <- get
  let self = state_self ctx
  if we_have_a_majority votes ctx
  then become Leader
  else do
    message <- awaitMessage electionTimeout
    case message of
      CastVote sender term | state_term ctx == term ->
        handleMessagesAsCandidate $ Set.insert sender votes
      AppendEntries sender term entries | term >= state_term ctx -> do
        if term > state_term ctx
        then setTerm term
        else return ()
        append entries
        ctx <- get
        put $ ctx { state_leader = Just sender }
        become Follower
      RequestVote sender term | term > state_term ctx -> do
        setTerm term
        castVote sender
        ctx <- get
        put $ ctx { state_leader = Nothing }
        become Follower
      Timeout sender | sender == saddr2addr (actor_addr self) -> become Candidate
      otherwise -> handleMessagesAsCandidate votes
  where -- we implicitly vote for ourselves by comparing >=
        -- instead of >
        we_have_a_majority votes ctx =
          Set.size votes >= length (state_peers ctx) `div` 2

handleMessagesAsLeader = do
  ctx <- get
  message <- awaitMessage broadcastTimeout
  case message of
    AppendEntries sender term entries | term > state_term ctx -> do
      append entries
      setTerm term
      unbecome Leader
      ctx <- get
      put $ ctx { state_leader = Just sender }
      become Follower
    RequestVote sender term | term > state_term ctx -> do
      setTerm term
      castVote sender
      unbecome Leader
      ctx <- get
      put $ ctx { state_leader = Nothing }
      become Follower
    otherwise -> handleMessagesAsLeader

newTerm :: ApplicationContext ()
newTerm = do
  ctx <- get
  put ctx { state_term = state_term ctx + 1 }

setTerm :: Term -> ApplicationContext ()
setTerm term = do
  ctx <- get
  put ctx { state_term = term }

setRole :: Role -> ApplicationContext ()
setRole role = do
  ctx <- get
  put ctx { state_role = role }

awaitMessage :: IO TimeoutMs -> ApplicationContext Message
awaitMessage ioTimeout = do
  timeout        <- lift ioTimeout
  ctx            <- get
  let self        = state_self ctx
  let selfAddr    = actor_addr self
  let timeoutMsg  = Timeout $ saddr2addr selfAddr
  timeoutThread  <- lift $ withTimeout timeout $ send (state_ssock ctx) (show timeoutMsg) selfAddr
  (msg, _, addr) <- lift $ recvFrom (state_rsock ctx) 1024
  lift $ killThread timeoutThread
  case reads msg of
    []                 -> return (Timeout $ saddr2addr $ actor_addr self)
    ((message, _) : _) -> log ("recvd: " ++ show message) >> return message

-- Spec says: choose a random value between 150--300 ms
-- we use a higher one to be able to see what's going on
electionTimeout :: IO TimeoutMs
electionTimeout = randomRIO (4000, 8000)

-- Spec says: choose a random value between 0.5--20 ms
-- we use a higher one to be able to see what's going on
broadcastTimeout :: IO TimeoutMs
broadcastTimeout = randomRIO (500, 1000)

-- TODO: implement
append :: [String] -> ApplicationContext ()
append entries = return ()

log :: String -> ApplicationContext ()
log = lift . putStrLn

sendMessage :: Message -> SockAddr -> ApplicationContext ()
sendMessage message addr = do
  ctx <- get
  let sock = state_ssock ctx
  lift $ send sock (show message) addr

broadcast :: Message -> ApplicationContext ()
broadcast message = do
  ctx <- get
  let peers = state_peers ctx
  mapM_ (\peer -> sendMessage message (actor_addr peer)) peers

castVote :: Address -> ApplicationContext ()
castVote recipientAddr = do
  ctx          <- get
  let self      = state_self ctx
  let term      = state_term ctx
  let peers     = state_peers ctx
  let recipient = filter ((== addr_to_string recipientAddr) . show . actor_addr) peers
  case recipient of
    []          -> log "ERROR: castVote: recipient not found"
    [recipient] -> sendMessage (CastVote (saddr2addr $ actor_addr self) term) (actor_addr recipient)
    _           -> log "ERROR: castVote: more than one recipient found"


flushQueue :: Actor -> Term -> MVar [String] -> [Actor] -> Socket -> IO ()
flushQueue self term mvEntries peers ssock = do
  entries    <- takeMVar mvEntries
  let message = AppendEntries (saddr2addr $ actor_addr self) term entries
  mapM_ (send ssock $ show message) (map actor_addr peers)
  putMVar mvEntries []

installSenderThread :: ApplicationContext ()
installSenderThread = do
  ctx       <- get
  let stimer = state_stimer ctx
  let self   = state_self ctx
  let term   = state_term ctx
  let squeue = state_squeue ctx
  let peers  = state_peers ctx
  let ssock  = state_ssock ctx
  let action = flushQueue self term squeue peers ssock
  stimerId  <- lift $ timerThread stimer action
  put $ ctx { state_sthr = Just stimerId }

uninstallSenderThread :: ApplicationContext ()
uninstallSenderThread = do
  ctx <- get
  let m_stimerId = state_sthr ctx
  case m_stimerId of
    Just stimerId -> lift $ killThread stimerId
    Nothing -> log "ERROR: uninstallSenderThread called with no thread running."
  put $ ctx { state_sthr = Nothing }

saddr2addr :: SockAddr -> Address
saddr2addr = Address . show
