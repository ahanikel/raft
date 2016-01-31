{-# LANGUAGE DeriveGeneric #-}

import Util (checkIO)
import Control.Monad.State (StateT, runStateT, get, put)
import Control.Distributed.Process (Process, ProcessId, expectTimeout, getSelfPid, say)
import Control.Distributed.Process.Backend.SimpleLocalnet (initializeBackend, newLocalNode)
import Control.Distributed.Process.Node (initRemoteTable, runProcess, LocalNode, localNodeId)
import Control.Monad.Trans (lift)
import Data.Binary (Binary)
import qualified Data.Set as Set
import Data.Typeable (Typeable)
import GHC.Generics (Generic)
import System.Environment (getArgs)
import System.Exit (exitWith, ExitCode(..))
import System.IO (stderr, hPutStrLn)
import Prelude hiding (log)

data Role               = Leader
                        | Follower
                        | Candidate
     deriving (Show, Read)

type Term = Integer

type Peer               = String

instance Show LocalNode where
  show = show . localNodeId

data ServerState        = ServerState { state_node  :: LocalNode
                                      , state_peers :: [Peer]
                                      , state_role  :: Role
                                      , state_term  :: Term
                                      }
     deriving (Show)

data Message            = AppendEntries ProcessId Term [String]
                        | RequestVote   ProcessId Term
                        | CastVote      ProcessId Term Peer
                        | Timeout
     deriving (Show, Generic, Typeable)

instance Binary Message

type ApplicationContext = StateT ServerState Process

type Timeout = Int

------------------------------------------------

peers = ["127.0.0.1:7000"]

main :: IO ()
main = do
  let usage = "Usage: raft host:port { host:port }"
  args <- getArgs
  case args of
    (self : peers) -> run self peers
    otherwise      -> do hPutStrLn stderr usage
                         exitWith $ ExitFailure 1

run :: String -> [Peer] -> IO ()
run self peers = do
  let (host, (':':port)) = span (/= ':') self
  backend <- initializeBackend host port initRemoteTable
  node    <- newLocalNode backend
  runProcess node $ do
    runStateT (become Follower)
              (ServerState node peers Follower 0)
    return ()
  

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
  myPid <- myProcessId
  broadcast $ RequestVote myPid (state_term ctx)
  handleMessagesAsCandidate Set.empty

become Leader    = do
  log "I am leader"
  setRole Leader
  handleMessagesAsLeader

handleMessagesAsFollower = do
  ctx <- get
  message <- awaitMessage messageTimeout
  case message of
    Timeout -> become Candidate
    AppendEntries sender term entries | term >= state_term ctx -> do
      append entries
      if term > state_term ctx
      then setTerm term
      else return ()
      handleMessagesAsFollower
    RequestVote sender term | term > state_term ctx -> do
      setTerm term
      castVote sender
      handleMessagesAsFollower
    otherwise -> handleMessagesAsFollower

handleMessagesAsCandidate votes = do
  ctx <- get
  if we_have_a_majority votes ctx
  then become Leader
  else do
    message <- awaitMessage electionTimeout
    case message of
      CastVote sender term peer | is_a_peer peer && state_term ctx == term ->
        handleMessagesAsCandidate $ Set.insert peer votes
      AppendEntries sender term entries | term >= state_term ctx ->
        if term > state_term ctx
        then setTerm term
        else return ()
        append entries
        become Follower
      RequestVote sender term | term > state_term ctx -> do
        setTerm term
        castVote sender
        become Follower
      Timeout -> become Candidate
      otherwise -> handleMessagesAsCandidate votes
  where -- we implicitly vote for ourselves by comparing >=
        -- instead of >
        -- TODO: check if this works (integer division, rounding)
        we_have_a_majority votes ctx =
          Set.size votes >= length (state_peers ctx) / 2

handleMessagesAsLeader = do
  ctx <- get
  message <- awaitMessage messageTimeout
  case message of
    Timeout -> do
      heartbeat
      handleMessagesAsLeader
    AppendEntries sender term entries | term > state_term ctx ->
      append entries
      setTerm term
      become Follower
    RequestVote sender term | term > state_term ctx -> do
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

awaitMessage :: Timeout -> ApplicationContext Message
awaitMessage timeout = do
  let await = lift $ expectTimeout timeout
  await :: ApplicationContext (Maybe Message)
  mmessage <- await
  case mmessage of
    Just message   -> return message
    Nothing        -> return Timeout

-- TODO: choose a random value between 150--300 ms
electionTimeout :: Timeout
electionTimeout = 300000

messageTimeout :: Timeout
messageTimeout = 300000

-- TODO: implement
append :: [String] -> ApplicationContext ()
append entries = return ()

heartbeat :: ApplicationContext ()
heartbeat = broadcast $ AppendEntries []

log :: String -> ApplicationContext ()
log = lift . say

broadcast :: Message -> ApplicationContext ()
broadcast message = undefined

castVote :: ProcessId -> ApplicationContext ()
castVote recipient = undefined

is_a_peer :: ProcessId -> Bool
is_a_peer peer = undefined

myProcessId :: ApplicationContext ProcessId
myProcessId = lift . getSelfPid
