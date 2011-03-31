module Hirc
  ( -- requireHandle

    -- * Types
    -- ** Hirc types
    Hirc
  , HircError (..)
  , HircState (..)
  , HircSettings (..)
    -- ** Managed types
  , Managed
  , ManagedState (..)
  , ManagedSettings (..)
    -- ** Connection types
  , IrcServer (..)
  , Reconnect (..)
  , ConnectionCommand (..)
  , Nickname
  , Username
  , Realname
  , To
    -- ** Logging
  , LogM (..)
  , LogSettings (..)

    -- * Reexports
    -- ** MState functions
  , get, gets, put, modifyM, forkM, killMState
    -- ** Reader functions
  , ask, asks, local
  ) where

import Control.Concurrent.MState
import Control.Monad.Reader
import Control.Monad.State.Class

import Types

{-
-}
