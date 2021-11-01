module JS.Lib.Sleep where

import Prelude as P hiding (const)
import JS

mkSleep :: (Expr Double -> Expr Double -> Expr Double) -> Expr Double -> M r ()
mkSleep f s = do
  e <- const $ getTime + (Cast $ f s $ lit 1000)
  while (getTime .<= e) empty

sleep :: Expr Double -> M r ()
sleep d = mkSleep (*) (Cast d)

usleep :: Expr Double -> M r ()
usleep = mkSleep (P./)
