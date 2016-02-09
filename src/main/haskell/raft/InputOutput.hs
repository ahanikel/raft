module InputOutput (TimeoutMs, Timer (..), withTimeout, timerThread) where

import           Control.Concurrent      ( ThreadId, forkIO, threadDelay )
import           Control.Concurrent.MVar ( MVar, takeMVar, putMVar )

type TimeoutMs          = Int

data Timer = Timer { timer_millis  :: IO TimeoutMs
                   , timer_current :: TimeoutMs
                   , timer_action  :: IO ()
                   }

withTimeout :: TimeoutMs -> IO () -> IO ThreadId
withTimeout millis action = forkIO $ do
  threadDelay (1000 * millis)
  action

timerThread :: MVar Timer -> IO () -> IO ThreadId
timerThread mvTimer ioAction = do
  timer  <- takeMVar mvTimer
  millis <- timer_millis timer
  putMVar mvTimer $ timer { timer_current = millis }
  forkIO loop
  where
    loop = do
      threadDelay 1000
      timer <- takeMVar mvTimer
      if timer_current timer <= 1 then do
        ioAction
        millis <- timer_millis timer
        putMVar mvTimer $ timer { timer_current = millis }
      else 
        putMVar mvTimer $ timer { timer_current = timer_current timer - 1 }
      loop
