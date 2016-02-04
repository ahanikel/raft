module Net where

import Network.Socket (Socket, getAddrInfo, socket, addrFamily, Datagram, defaultProtocol)

data Transmitter = Transmitter { t_send  :: String -> IO ()
                               , t_close :: Socket -> IO ()
                               }

transmitter :: String -> String -> IO Transmitter
transmitter host port = do
  addrInfos   <- getAddrInfo Nothing (Just host) (Just port)
  let addrInfo = head addrInfos
  sock        <- socket (addrFamily addrInfo) Datagram defaultProtocol
  return $ Transmitter sendFunc (close sock)
  where
    sendFunc :: String -> IO ()
    sendFunc [] = return ()
    sendFunc s  = do
      nSent <- sendTo sock s (addrAddress addrInfo)
      sendFunc (drop nSent s)

data Receiver = Receiver { r_receive :: IO String
                         , r_close :: Socket -> IO ()
                         }

receiver :: String -> IO Receiver
receiver port = withSocketsDo $ do
  addrInfos <- getAddrInfo (Just (defaultHints { addrFlags = [ AI_PASSIVE ] }))
                           Nothing
                           (Just port)
  let addrInfo = head addrInfos
  sock <- socket (addrFamily addrInfo) Datagram defaultProtocol
  bindSocket sock (addrAddress addrInfo)
  return $ Receiver (receiveFunc sock) (close sock)
  where
    receiveFunc sock = do
      (msg, _, addr) <- recvFrom sock 1024
      -- TODO: check timeout
      return (msg, addr)
