{-# LANGUAGE DeriveGeneric #-}

import Util (checkIO)
import Control.Monad.State (StateT, runStateT, get, put)
import Control.Monad.Trans (lift)
import qualified Data.Set as Set
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Socket (Socket, AddrInfo, getAddrInfo, socket, addrFamily, SocketType(..), defaultProtocol, SockAddr, addrAddress, sendTo, SockAddr(..), AddrInfoFlag(AI_PASSIVE), defaultHints, addrFlags, bindSocket)
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode(..))
import System.IO (stderr, hPutStrLn)
import Prelude hiding (log)

data Role               = Leader
                        | Follower
                        | Candidate
     deriving (Show, Read)

type Term = Integer

data Actor = Self AddrInfo | Peer AddrInfo
  deriving (Show, Eq)

data ServerState        = ServerState { state_self  :: Actor
                                      , state_peers :: [Actor]
                                      , state_ssock :: Socket
                                      , state_rsock :: Socket
                                      , state_role  :: Role
                                      , state_term  :: Term
                                      }
     deriving (Show)

data Message            = AppendEntries Term [String]
                        | RequestVote   Term
                        | CastVote      Term String
                        | Timeout
     deriving (Show, Read)

type ApplicationContext = StateT ServerState IO

type Timeout = Int

------------------------------------------------

getAddress :: String -> IO AddrInfo
getAddress addr = getAddrInfo Nothing (Just host) (Just port) >>= returnFirst
  where
    (host, (':' : port)) = span (/= ':') addr
    returnFirst = return . head

main :: IO ()
main = do
  let usage = "Usage: raft host:port { host:port }"
  args <- getArgs
  case args of
    []        -> do hPutStrLn stderr usage
                    exitWith $ ExitFailure 1
    otherwise -> mapM getAddress args >>= \(self : peers) -> run (Self self) (fmap Peer peers)

run :: Actor -> [Actor] -> IO ()
run self peers = do
  let Self selfInfo = self
  ssock' <- ssock selfInfo
  rsock' <- rsock selfInfo
  runStateT (become Follower)
            (ServerState self peers ssock' rsock' Follower 0)
  return ()
  where
    ssock :: AddrInfo -> IO Socket
    ssock selfInfo = socket (addrFamily selfInfo) Datagram defaultProtocol
      
    rsock :: AddrInfo -> IO Socket
    rsock selfInfo = do
      let SockAddrInet port _ = addrAddress selfInfo
      raddrInfo <- fmap head $ getAddrInfo (Just (defaultHints { addrFlags = [ AI_PASSIVE ] }))
                                           Nothing
                                           (Just $ show port)
      rsock <- socket (addrFamily raddrInfo) Datagram defaultProtocol
      bindSocket rsock (addrAddress raddrInfo)
      return rsock
 
become :: Role -> ApplicationContext ()
become Follower  = do
  log "I am follower"
  setRole Follower
  handleMessagesAsFollower

become Candidate = do
  ctx <- get
  log "I am candidate"
  newTerm
  setRole Candidate
  broadcast $ RequestVote (state_term ctx)
  handleMessagesAsCandidate Set.empty

become Leader    = do
  log "I am leader"
  setRole Leader
  handleMessagesAsLeader

handleMessagesAsFollower = do
  ctx <- get
  (sender, message) <- awaitMessage messageTimeout
  case message of
    Timeout -> become Candidate
    AppendEntries term entries | term >= state_term ctx -> do
      append entries
      if term > state_term ctx
      then setTerm term
      else return ()
      handleMessagesAsFollower
    RequestVote term | term > state_term ctx -> do
      setTerm term
      castVote sender
      handleMessagesAsFollower
    otherwise -> handleMessagesAsFollower

handleMessagesAsCandidate votes = do
  ctx <- get
  if we_have_a_majority votes ctx
  then become Leader
  else do
    (sender, message) <- awaitMessage electionTimeout
    case message of
      CastVote term peer | is_a_peer peer && state_term ctx == term ->
        handleMessagesAsCandidate $ Set.insert peer votes
      AppendEntries term entries | term >= state_term ctx -> do
        if term > state_term ctx
        then setTerm term
        else return ()
        append entries
        become Follower
      RequestVote term | term > state_term ctx -> do
        setTerm term
        castVote sender
        become Follower
      Timeout -> become Candidate
      otherwise -> handleMessagesAsCandidate votes
  where -- we implicitly vote for ourselves by comparing >=
        -- instead of >
        -- TODO: check if this works (integer division, rounding)
        we_have_a_majority votes ctx =
          Set.size votes >= length (state_peers ctx) `div` 2

handleMessagesAsLeader = do
  ctx <- get
  (sender, message) <- awaitMessage messageTimeout
  case message of
    Timeout -> do
      heartbeat
      handleMessagesAsLeader
    AppendEntries term entries | term > state_term ctx -> do
      append entries
      setTerm term
      become Follower
    RequestVote term | term > state_term ctx -> do
      setTerm term
      castVote sender
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

awaitMessage :: Timeout -> ApplicationContext (Actor, Message)
awaitMessage timeout = do
  ctx <- get
  let self = state_self ctx
  let await = lift $ expectTimeout timeout
  await :: ApplicationContext (Maybe (Actor, Message))
  mmessage <- await
  case mmessage of
    Just message   -> return message
    Nothing        -> return (self, Timeout)

-- TODO: choose a random value between 150--300 ms
electionTimeout :: Timeout
electionTimeout = 300000

messageTimeout :: Timeout
messageTimeout = 300000

-- TODO: implement
append :: [String] -> ApplicationContext ()
append entries = return ()

heartbeat :: ApplicationContext ()
heartbeat = do
  ctx <- get
  broadcast $ AppendEntries (state_term ctx) []

log :: String -> ApplicationContext ()
log = lift . putStrLn

send :: Message -> SockAddr -> ApplicationContext ()
send message addr = do
  ctx <- get
  let sock = state_ssock ctx
  lift $ send' sock (show message) addr
  where
    send' _    []      _    = return ()
    send' sock message addr = do
      nSent <- sendTo sock message addr
      send' sock (drop nSent message) addr

broadcast :: Message -> ApplicationContext ()
broadcast message = do
  ctx <- get
  let peers = state_peers ctx
  mapM_ (\(Peer peer) -> send message $ addrAddress peer) peers

castVote :: Actor -> ApplicationContext ()
castVote recipient = undefined

is_a_peer :: String -> Bool
is_a_peer peer = undefined

expectTimeout :: Timeout -> IO (Maybe (Actor, Message))
expectTimeout timeout = undefined
