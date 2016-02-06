{-# LANGUAGE DeriveGeneric #-}

import Util (checkIO)
import Control.Concurrent (ThreadId, forkIO, threadDelay, killThread)
import Control.Concurrent.MVar (MVar, newMVar, takeMVar, putMVar)
import Control.Monad.State (StateT, runStateT, get, put)
import Control.Monad.Trans (lift)
import qualified Data.Set as Set
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import Network.Socket ( Socket, AddrInfo, SocketType(..), SockAddr(..), AddrInfoFlag(AI_PASSIVE)
                      , getAddrInfo, socket, addrFamily, defaultProtocol, addrAddress, sendTo, defaultHints, addrFlags, bindSocket, recvFrom
                      )
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode(..))
import System.IO (stderr, hPutStrLn)
import Prelude hiding (log)

data Role               = Leader
                        | Follower
                        | Candidate
  deriving (Show, Read)

type Term = Integer

newtype Address = Address { addr_to_string :: String }
  deriving (Show, Read, Eq, Ord)

data Actor = Actor { actor_addr :: SockAddr }
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

type Timeout = Int

------------------------------------------------

main :: IO ()
main = do
  let usage = "Usage: raft host:port { host:port }"
  args <- getArgs
  case args of
    []        -> do hPutStrLn stderr usage
                    exitWith $ ExitFailure 1
    otherwise -> mapM getAddressInfo args >>= \(self : peers) -> run self (fmap (Actor . addrAddress) peers)

getAddressInfo :: String -> IO AddrInfo
getAddressInfo addr = getAddrInfo Nothing (Just host) (Just port) >>= returnFirst
  where
    (host, (':' : port)) = span (/= ':') addr
    returnFirst = return . head

run :: AddrInfo -> [Actor] -> IO ()
run selfInfo peers = do
  ssock' <- ssock selfInfo
  rsock' <- rsock selfInfo
  squeue <- newMVar []
  stimer <- newMVar $ Timer broadcastTimeout 0 (return ())
  runStateT (become Follower)
            (ServerState (Actor $ addrAddress selfInfo) peers ssock' rsock' Follower 0 squeue stimer Nothing Nothing)
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
        -- TODO: check if this works (integer division, rounding)
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

awaitMessage :: IO Timeout -> ApplicationContext Message
awaitMessage ioTimeout = do
  timeout <- lift ioTimeout
  ctx <- get
  let self = state_self ctx
  mmessage <- expectTimeout timeout
  case mmessage of
    Just message   -> return message
    Nothing        -> return (Timeout $ saddr2addr $ actor_addr self)

-- TODO: choose a random value between 150--300 ms
electionTimeout :: IO Timeout
electionTimeout = return 8000

-- TODO: choose a random value between 0.5--20 ms
broadcastTimeout :: IO Timeout
broadcastTimeout = return 1000

-- TODO: implement
append :: [String] -> ApplicationContext ()
append entries = return ()

log :: String -> ApplicationContext ()
log = lift . putStrLn

send' :: Socket -> String -> SockAddr -> IO ()
send' _    []      _    = return ()
send' sock message addr = do
  nSent <- sendTo sock message addr
  putStrLn $ "sending " ++ message
  send' sock (drop nSent message) addr

send :: Message -> SockAddr -> ApplicationContext ()
send message addr = do
  ctx <- get
  let sock = state_ssock ctx
  lift $ send' sock (show message) addr

broadcast :: Message -> ApplicationContext ()
broadcast message = do
  ctx <- get
  let peers = state_peers ctx
  mapM_ (\peer -> send message (actor_addr peer)) peers

castVote :: Address -> ApplicationContext ()
castVote recipientAddr = do
  ctx <- get
  let self = state_self ctx
  let term = state_term ctx
  let peers = state_peers ctx
  let recipient = filter ((== addr_to_string recipientAddr) . show . actor_addr) peers
  case recipient of
    []          -> log "ERROR: castVote: recipient not found"
    [recipient] -> send (CastVote (saddr2addr $ actor_addr self) term) (actor_addr recipient)
    _           -> log "ERROR: castVote: more than one recipient found"

withTimeout :: Int -> IO () -> IO ThreadId
withTimeout millis action = forkIO $ do
  threadDelay (1000 * millis)
  action

expectTimeout :: Timeout -> ApplicationContext (Maybe Message)
expectTimeout timeout = do
  ctx            <- get
  let self        = state_self ctx
  let selfAddr    = actor_addr self
  timeoutThread  <- lift $ withTimeout timeout $ send' (state_ssock ctx) (show $ Timeout $ saddr2addr selfAddr) selfAddr
  (msg, _, addr) <- lift $ recvFrom (state_rsock ctx) 1024
  lift $ killThread timeoutThread
  result <- case reads msg of
    []                 -> return Nothing
    ((message, _) : _) -> return $ Just message
  log ("got " ++ show result)
  return result

data Timer = Timer { timer_millis  :: IO Int
                   , timer_current :: Int
                   , timer_action  :: IO ()
                   }

timerThread :: MVar Timer -> IO () -> ApplicationContext ThreadId
timerThread mvTimer ioAction = do
  timer  <- lift $ takeMVar mvTimer
  millis <- lift $ timer_millis timer
  lift $ putMVar mvTimer $ timer { timer_current = millis }
  lift $ forkIO loop
  where
    loop = do
      threadDelay 1000
      timer <- takeMVar mvTimer
      if timer_current timer <= 1 then do
        putStrLn "Performing timed action"
        ioAction
        millis <- timer_millis timer
        putMVar mvTimer $ timer { timer_current = millis }
      else 
        putMVar mvTimer $ timer { timer_current = timer_current timer - 1 }
      loop

flushQueue :: Actor -> Term -> MVar [String] -> [Actor] -> Socket -> IO ()
flushQueue self term mvEntries peers ssock = do
  entries <- takeMVar mvEntries
  let message = AppendEntries (saddr2addr $ actor_addr self) term entries
  mapM_ (send' ssock $ show message) (map actor_addr peers)
  putMVar mvEntries []

installSenderThread :: ApplicationContext ()
installSenderThread = do
  ctx <- get
  let stimer = state_stimer ctx
  let self   = state_self ctx
  let term   = state_term ctx
  let squeue = state_squeue ctx
  let peers  = state_peers ctx
  let ssock  = state_ssock ctx
  stimerId  <- timerThread stimer $ flushQueue self term squeue peers ssock
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
