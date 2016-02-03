module Net where

import Network.Socket (Socket, getAddrInfo, socket, addrFamily, Datagram, defaultProtocol)

data Connection = Connection { c_socket :: Socket
                             , c_send   :: String -> IO ()
                             }

open :: String -> String -> IO Connection
open = do
  addrInfos   <- getAddrInfo Nothing (Just host) (Just port)
  let addrInfo = head addrInfos
  sock        <- socket (addrFamily addrInfo) Datagram defaultProtocol
  return $ Connection sock sendFunc
  where
    sendFunc :: String -> IO ()
    sendFunc [] = return ()
    sendFunc s  = do
      nSent <- sendTo sock s (addrAddress addrInfo)
      sendFunc (drop nSent s)

type HandlerFunc = SockAddr -> String -> IO ()

receive port handlerFunc = withSocketsDo $ do
  addrInfos <- getAddrInfo (Just (defaultHints { addrFlags = [ AI_PASSIVE ] }))
                           Nothing
                           (Just port)
  let addrInfo = head addrInfos
  sock <- socket (addrFamily addrInfo) Datagram defaultProtocol
  bindSocket sock (addrAddress addrInfo)
  procMessages sock
  where
    procMessages sock = do
      (msg, _, addr) <- recvFrom sock 1024
      handlerFunc addr msg
      -- TODO: check timeout
      procMessages sock
