module Net where

import Network.Socket ( Socket
                      , getAddrInfo
                      , socket
                      , addrFamily
                      , SocketType(Datagram)
                      , defaultProtocol
                      , close
                      , sendTo
                      , addrAddress
                      , withSocketsDo
                      , defaultHints
                      , addrFlags
                      , AddrInfo
                      , AddrInfoFlag(AI_PASSIVE)
                      , bindSocket
                      , recvFrom
                      , SockAddr
                      )

data Transmitter = Transmitter { t_send  :: String -> IO ()
                               , t_close :: IO ()
                               }

transmitter :: String -> String -> IO Transmitter
transmitter host port = do
  addrInfo <- fmap head $ getAddrInfo Nothing (Just host) (Just port)
  sock     <- socket (addrFamily addrInfo) Datagram defaultProtocol
  return $ Transmitter (sendFunc sock addrInfo) (close sock)
  where
    sendFunc :: Socket -> AddrInfo -> String -> IO ()
    sendFunc _ _ []           = return ()
    sendFunc sock addrInfo s  = do
      nSent <- sendTo sock s (addrAddress addrInfo)
      sendFunc sock addrInfo (drop nSent s)

data Receiver = Receiver { r_receive :: IO (String, SockAddr)
                         , r_close   :: IO ()
                         }

receiver :: String -> IO Receiver
receiver port = withSocketsDo $ do
  addrInfo <- fmap head $ getAddrInfo (Just (defaultHints { addrFlags = [ AI_PASSIVE ] }))
                                      Nothing
                                      (Just port)
  sock <- socket (addrFamily addrInfo) Datagram defaultProtocol
  bindSocket sock (addrAddress addrInfo)
  return $ Receiver (receiveFunc sock) (close sock)
  where
    receiveFunc sock = do
      (msg, _, addr) <- recvFrom sock 1024
      -- TODO: check timeout
      return (msg, addr)
