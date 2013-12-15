{-# LANGUAGE DoAndIfThenElse #-}

module Inference where

import Debug.Trace
import qualified Data.Set as S
import Control.Monad.Reader
import Control.Monad.Trans.State.Lazy
import Control.Monad.Trans.Writer.Strict
import Control.Monad.Random hiding (randoms) -- From cabal install MonadRandom
import Control.Lens -- From cabal install lens

import Utils
import Language hiding (Exp, Value, Env)
import Trace
import Regen
import Detach hiding (empty)
import qualified Detach as D (empty)

type Kernel m a = a -> WriterT LogDensity m a

mix_mh_kernels :: (Monad m) => (a -> m ind) -> (a -> ind -> LogDensity) ->
                  (ind -> Kernel m a) -> (Kernel m a)
mix_mh_kernels sampleIndex measureIndex paramK x = do
  ind <- lift $ sampleIndex x
  let ldRho = measureIndex x ind
  tell ldRho
  x' <- paramK ind x
  let ldXi = measureIndex x' ind
  tell $ log_density_negate ldXi
  return x'

metropolis_hastings :: (MonadRandom m) => Kernel m a -> a -> m a
metropolis_hastings propose x = do
  (x', (LogDensity alpha)) <- runWriterT $ propose x
  u <- getRandomR (0.0,1.0)
  if (log u < alpha) then
      return x'
  else
      return x

-- TODO Is this a standard combinator too?
modifyM :: Monad m => (s -> m s) -> StateT s m ()
modifyM act = get >>= (lift . act) >>= put

scaffold_mh_kernel :: (MonadRandom m) => Scaffold -> Kernel m (Trace m)
scaffold_mh_kernel scaffold trace = do
  torus <- censor log_density_negate $ stupid $ detach scaffold trace
  regen scaffold torus
        where stupid :: (Monad m) => Writer w a -> WriterT w m a
              stupid = WriterT . return . runWriter

principal_node_mh :: (MonadRandom m) => Kernel m (Trace m)
principal_node_mh = mix_mh_kernels sample log_density scaffold_mh_kernel where
    sample :: (MonadRandom m) => Trace m -> m Scaffold
    sample trace =
        if trace^.randoms.to S.size == 0 then return D.empty
        else do
          index <- getRandomR (0, trace^.randoms.to S.size - 1)
          let addr = (trace^.randoms.to S.toList) !! index
          let scaffold = runReader (scaffold_from_principal_node addr) (traceShowTrace trace)
          return $ traceShow (pp scaffold) scaffold

    log_density :: Trace m -> a -> LogDensity
    log_density t _ = LogDensity $ -log(fromIntegral $ t^.randoms.to S.size)
