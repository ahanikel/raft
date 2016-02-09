module Net (getAddressInfo, send) where

import           Network.Socket          ( Socket, AddrInfo, SockAddr, getAddrInfo, sendTo )

getAddressInfo :: String -> IO AddrInfo
getAddressInfo addr = getAddrInfo Nothing (Just host) (Just port) >>= returnFirst
  where
    (host, (':' : port)) = span (/= ':') addr
    returnFirst = return . head

send :: Socket -> String -> SockAddr -> IO ()
send _    []      _    = return ()
send sock message addr = do
  nSent <- sendTo sock message addr
  putStrLn $ "sending " ++ message
  send sock (drop nSent message) addr
