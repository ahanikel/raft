module Util where

import Control.Monad.Trans.Either ( EitherT (..)
                                  , runEitherT
                                  )
import System.IO.Error            ( tryIOError )

-- from https://hackage.haskell.org/package/mmorph-1.0.0/docs/Control-Monad-Morph.html
check :: IO a -> EitherT IOError IO a
check io = EitherT (tryIOError io)

checkIO :: IO a -> IO (Either IOError a)
checkIO = runEitherT . check
