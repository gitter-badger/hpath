{-# LANGUAGE DeriveDataTypeable #-}

-- | Internal types and functions.

module HPath.Internal
  (Path(..)
  ,RelC)
  where

import Control.DeepSeq (NFData (..))
import Data.ByteString (ByteString)
import Data.Data

-- | Path of some base and type.
--
-- Internally is a string. The string can be of two formats only:
--
-- 1. without trailing path separator: @file.txt@, @foo\/bar.txt@, @\/foo\/bar.txt@
-- 2. with trailing path separator: @foo\/@, @\/foo\/bar\/@
--
-- There are no duplicate
-- path separators @\/\/@, no @..@, no @.\/@, no @~\/@, etc.
data Path b = MkPath ByteString
  deriving (Typeable)

-- | String equality.
--
-- The following property holds:
--
-- @show x == show y ≡ x == y@
instance Eq (Path b) where
  (==) (MkPath x) (MkPath y) = x == y

-- | String ordering.
--
-- The following property holds:
--
-- @show x \`compare\` show y ≡ x \`compare\` y@
instance Ord (Path b) where
  compare (MkPath x) (MkPath y) = compare x y

-- | Same as 'Path.toFilePath'.
--
-- The following property holds:
--
-- @x == y ≡ show x == show y@
instance Show (Path b) where
  show (MkPath x) = show x

instance NFData (Path b) where
  rnf (MkPath x) = rnf x


class RelC m

