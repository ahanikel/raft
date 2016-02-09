import           Net                     ( getAddressInfo )
import           Raft                    ( Actor (..), init )
import           Network.Socket          ( Socket, AddrInfo, SocketType(Datagram), SockAddr(..), AddrInfoFlag(AI_PASSIVE)
                                         , getAddrInfo, socket, addrFamily, defaultProtocol, addrAddress
                                         , defaultHints, addrFlags, bindSocket
                                         )
import           System.Environment      ( getArgs )
import           System.Exit             ( exitWith, ExitCode(..) )
import           System.IO               ( stderr, hPutStrLn )
import           Prelude                 hiding ( init )

main :: IO ()
main = do
  let usage = "Usage: raft host:port { host:port }"
  args <- getArgs
  case args of
    []        -> do hPutStrLn stderr usage
                    exitWith $ ExitFailure 1
    otherwise -> mapM getAddressInfo args >>= \(self : peers) -> run self (fmap (Actor . addrAddress) peers)

run :: AddrInfo -> [Actor] -> IO ()
run selfInfo peers = do
  ssock' <- ssock selfInfo
  rsock' <- rsock selfInfo
  init (Actor $ addrAddress selfInfo) peers ssock' rsock'
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
 
