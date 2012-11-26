{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  Control.Lens.Internal.Zipper
-- Copyright   :  (C) 2012 Edward Kmett
-- License     :  BSD-style (see the file LICENSE)
-- Maintainer  :  Edward Kmett <ekmett@gmail.com>
-- Stability   :  experimental
-- Portability :  non-portable
--
-- This module provides internal types and functions used in the implementation
-- of Control.Lens.Zipper. You shouldn't need to import it directly, and the
-- exported types can be used to break Zipper invariants.
--
----------------------------------------------------------------------------
module Control.Lens.Internal.Zipper where

import Control.Applicative
import Control.Category
import Control.Monad ((>=>))
import Control.Lens.Indexed
import Control.Lens.IndexedLens
import Control.Lens.Internal
import Control.Lens.Traversal
import Control.Lens.Type
import Data.Maybe
import Prelude hiding ((.),id)

-----------------------------------------------------------------------------
-- * Zippers
-----------------------------------------------------------------------------

-- | This is used to represent the 'Top' of the 'zipper'.
--
-- Every 'zipper' starts with 'Top'.
--
-- /e.g./ @'Top' ':>' a@ is the trivial zipper.
data Top

infixl 9 :>

-- | This is the type of a 'zipper'. It visually resembles a \"breadcrumb trail\" as
-- used in website navigation. Each breadcrumb in the trail represents a level you
-- can move up to.
--
-- This type operator associates to the left, so you can use a type like
--
-- @'Top' ':>' ('String','Double') ':>' 'String' ':>' 'Char'@
--
-- to represent a zipper from @('String','Double')@ down to 'Char' that has an intermediate
-- crumb for the 'String' containing the 'Char'.
data p :> a = Zipper (Coil p a) {-# UNPACK #-} !Int [a] a [a]

-- | This represents the type a zipper will have when it is fully 'Zipped' back up.
type family Zipped h a
type instance Zipped Top a      = a
type instance Zipped (h :> b) a = Zipped h b

-- | 'Coil' is used internally in the definition of a 'zipper'.
data Coil :: * -> * -> * where
  Coil :: Coil Top a
  Snoc :: Coil h b ->
          SimpleLensLike (Bazaar a a) b a ->
          {-# UNPACK #-} !Int ->
          [b] -> ([a] -> b) -> [b] ->
          Coil (h :> b) a

-- | This 'Lens' views the current target of the 'zipper'.
focus :: SimpleIndexedLens (Tape (h :> a)) (h :> a) a
focus = index $ \f (Zipper h n l a r) -> (\a' -> Zipper h n l a' r) <$> f (Tape (peel h) n) a
{-# INLINE focus #-}

-- | Construct a 'zipper' that can explore anything.
zipper :: a -> Top :> a
zipper a = Zipper Coil 0 [] a []
{-# INLINE zipper #-}

-- | Return the index into the current 'Traversal' within the current level of the zipper.
--
-- @'jerkTo' ('tooth' l) l = Just'@
tooth :: (a :> b) -> Int
tooth (Zipper _ n _ _ _) = n
{-# INLINE tooth #-}

-- | Move the 'zipper' 'up', closing the current level and focusing on the parent element.
up :: (a :> b :> c) -> a :> b
up (Zipper (Snoc h _ un uls k urs) _ ls x rs) = Zipper h un uls ux urs
  where ux = k (reverseList ls ++ x : rs)
{-# INLINE up #-}

-- | Pull the 'zipper' 'left' within the current 'Traversal'.
left  :: (a :> b) -> Maybe (a :> b)
left (Zipper _ _ []     _ _ ) = Nothing
left (Zipper h n (l:ls) a rs) = Just (Zipper h (n - 1) ls l (a:rs))
{-# INLINE left #-}

-- | Pull the entry one entry to the 'right'
right :: (a :> b) -> Maybe (a :> b)
right (Zipper _ _ _  _ []    ) = Nothing
right (Zipper h n ls a (r:rs)) = Just (Zipper h (n + 1) (a:ls) r rs)
{-# INLINE right #-}

-- | This allows you to safely 'tug left' or 'tug right' on a 'zipper'.
--
-- The more general signature allows its use in other circumstances, however.
tug :: (a -> Maybe a) -> a -> a
tug f a = fromMaybe a (f a)
{-# INLINE tug #-}

-- | This allows you to safely 'tug left' or 'tug right' on a 'zipper', moving multiple steps in a given direction,
-- stopping at the last place you couldn't move from.
tugs :: (a -> Maybe a) -> Int -> a -> a
tugs f n0
  | n0 < 0    = error "tugs: negative tug count"
  | otherwise = go n0
  where
    go 0 a = a
    go n a = maybe a (go (n - 1)) (f a)
{-# INLINE tugs #-}

-- | Move in a direction as far as you can go, then stop.
farthest :: (a -> Maybe a) -> a -> a
farthest f = go where
  go a = maybe a go (f a)
{-# INLINE farthest #-}

-- | This allows for you to repeatedly pull a 'zipper' in a given direction, failing if it falls off the end.
jerks :: (a -> Maybe a) -> Int -> a -> Maybe a
jerks f n0
  | n0 < 0    = error "jerks: negative jerk count"
  | otherwise = go n0
  where
    go 0 a = Just a
    go n a = f a >>= go (n - 1)
{-# INLINE jerks #-}

-- | Returns the number of siblings at the current level in the 'zipper'.
--
-- @'teeth' z '>=' 1@
--
-- /NB:/ If the current 'Traversal' targets an infinite number of elements then this may not terminate.
teeth :: (a :> b) -> Int
teeth (Zipper _ n _ _ rs) = n + 1 + length rs
{-# INLINE teeth #-}

-- | Move the 'zipper' horizontally to the element in the @n@th position in the current level, absolutely indexed, starting with the @'farthest' 'left'@ as @0@.
--
-- This returns 'Nothing' if the target element doesn't exist.
--
-- @'jerkTo' n ≡ 'jerks' 'right' n . 'farthest' 'left'@
jerkTo :: Int -> (a :> b) -> Maybe (a :> b)
jerkTo n z = case compare k n of
  LT -> jerks left (n - k) z
  EQ -> Just z
  GT -> jerks right (k - n) z
  where k = tooth z
{-# INLINE jerkTo #-}

-- | Move the 'zipper' horizontally to the element in the @n@th position of the current level, absolutely indexed, starting with the @'farthest' 'left'@ as @0@.
--
-- If the element at that position doesn't exist, then this will clamp to the range @0 <= n < 'teeth'@.
--
-- @'tugTo' n ≡ 'tugs' 'right' n . 'farthest' 'left'@
tugTo :: Int -> (a :> b) -> a :> b
tugTo n z = case compare k n of
  LT -> tugs left (n - k) z
  EQ -> z
  GT -> tugs right (k - n) z
  where k = tooth z
{-# INLINE tugTo #-}

-- | Step down into a 'Lens'. This is a constrained form of 'fromWithin' for when you know
-- there is precisely one target.
--
-- @
-- 'down' :: 'Simple' 'Lens' b c -> (a :> b) -> a :> b :> c
-- 'down' :: 'Simple' 'Iso' b c  -> (a :> b) -> a :> b :> c
-- @
down :: SimpleLensLike (Context c c) b c -> (a :> b) -> a :> b :> c
down l (Zipper h n ls b rs) = case l (Context id) b of
  Context k c -> Zipper (Snoc h (cloneLens l) n ls (k . head) rs) 0 [] c []
{-# INLINE down #-}

-- | Step down into the 'leftmost' entry of a 'Traversal'.
--
-- @
-- 'within' :: 'Simple' 'Traversal' b c -> (a :> b) -> Maybe (a :> b :> c)
-- 'within' :: 'Simple' 'Lens' b c      -> (a :> b) -> Maybe (a :> b :> c)
-- 'within' :: 'Simple' 'Iso' b c       -> (a :> b) -> Maybe (a :> b :> c)
-- @
within :: SimpleLensLike (Bazaar c c) b c -> (a :> b) -> Maybe (a :> b :> c)
within l (Zipper h n ls b rs) = case partsOf' l (Context id) b of
  Context _ []     -> Nothing
  Context k (c:cs) -> Just (Zipper (Snoc h l n ls k rs) 0 [] c cs)
{-# INLINE within #-}

-- | Unsafely step down into a 'Traversal' that is /assumed/ to be non-empty.
--
-- If this invariant is not met then this will usually result in an error!
--
-- @
-- 'fromWithin' :: 'Simple' 'Traversal' b c -> (a :> b) -> a :> b :> c
-- 'fromWithin' :: 'Simple' 'Lens' b c      -> (a :> b) -> a :> b :> c
-- 'fromWithin' :: 'Simple' 'Iso' b c       -> (a :> b) -> a :> b :> c
-- @
--
-- You can reason about this function as if the definition was:
--
-- @'fromWithin' l ≡ 'fromJust' '.' 'within' l@
--
-- but it is lazier in such a way that if this invariant is violated, some code
-- can still succeed if it is lazy enough in the use of the focused value.
fromWithin :: SimpleLensLike (Bazaar c c) b c -> (a :> b) -> a :> b :> c
fromWithin l (Zipper h n ls b rs) = case partsOf' l (Context id) b of
  Context k ~(c:cs) -> Zipper (Snoc h l n ls k rs) 0 [] c cs
{-# INLINE fromWithin #-}

-- | This enables us to pull the 'zipper' back up to the 'Top'.
class Zipper h a where
  recoil :: Coil h a -> [a] -> Zipped h a

instance Zipper Top a where
  recoil Coil = head
  {-# INLINE recoil #-}

instance Zipper h b => Zipper (h :> b) c where
  recoil (Snoc h _ _ ls k rs) as = recoil h (reverseList ls ++ k as : rs)
  {-# INLINE recoil #-}

-- | Close something back up that you opened as a 'zipper'.
rezip :: Zipper h a => (h :> a) -> Zipped h a
rezip (Zipper h _ ls a rs) = recoil h (reverseList ls ++ a : rs)
{-# INLINE rezip #-}

-----------------------------------------------------------------------------
-- * Tapes
-----------------------------------------------------------------------------

-- | A 'Tape' is a recorded path through the 'Traversal' chain of a 'zipper'.
data Tape k where
  Tape :: Track h a -> {-# UNPACK #-} !Int -> Tape (h :> a)

-- | Save the current path as as a 'Tape' we can play back later.
saveTape :: (a :> b) -> Tape (a :> b)
saveTape (Zipper h n _ _ _) = Tape (peel h) n
{-# INLINE saveTape #-}

-- | Restore ourselves to a previously recorded position precisely.
--
-- If the position does not exist, then fail.
restoreTape :: Tape (h :> a) -> Zipped h a -> Maybe (h :> a)
restoreTape (Tape h n) = restoreTrack h >=> jerks right n
{-# INLINE restoreTape #-}

-- | Restore ourselves to a location near our previously recorded position.
--
-- When moving left to right through a 'Traversal', if this will clamp at each level to the range @0 <= k < teeth@,
-- so the only failures will occur when one of the sequence of downward traversals find no targets.
restoreNearTape :: Tape (h :> a) -> Zipped h a -> Maybe (h :> a)
restoreNearTape (Tape h n) a = tugs right n <$> restoreNearTrack h a
{-# INLINE restoreNearTape #-}

-- | Restore ourselves to a previously recorded position.
--
-- This *assumes* that nothing has been done in the meantime to affect the existence of anything on the entire path.
--
-- Motions left or right are clamped, but all traversals included on the 'Tape' are assumed to be non-empty.
--
-- Violate these assumptions at your own risk!
unsafelyRestoreTape :: Tape (h :> a) -> Zipped h a -> h :> a
unsafelyRestoreTape (Tape h n) = unsafelyRestoreTrack h >>> tugs right n
{-# INLINE unsafelyRestoreTape #-}

-----------------------------------------------------------------------------
-- * Tracks
-----------------------------------------------------------------------------

-- | This is used to peel off the path information from a 'Coil' for use when saving the current path for later replay.
peel :: Coil h a -> Track h a
peel Coil               = Track
peel (Snoc h l n _ _ _) = Fork (peel h) n l

-- | The 'Track' forms the bulk of a 'Tape'.
data Track :: * -> * -> * where
  Track :: Track Top a
  Fork  :: Track h b -> {-# UNPACK #-} !Int -> SimpleLensLike (Bazaar a a) b a -> Track (h :> b) a

-- | Restore ourselves to a previously recorded position precisely.
--
-- If the position does not exist, then fail.
restoreTrack :: Track h a -> Zipped h a -> Maybe (h :> a)
restoreTrack Track = Just . zipper
restoreTrack (Fork h n l) = restoreTrack h >=> jerks right n >=> within l

-- | Restore ourselves to a location near our previously recorded position.
--
-- When moving left to right through a 'Traversal', if this will clamp at each level to the range @0 <= k < teeth@,
-- so the only failures will occur when one of the sequence of downward traversals find no targets.
restoreNearTrack :: Track h a -> Zipped h a -> Maybe (h :> a)
restoreNearTrack Track = Just . zipper
restoreNearTrack (Fork h n l) = restoreNearTrack h >=> tugs right n >>> within l

-- | Restore ourselves to a previously recorded position.
--
-- This *assumes* that nothing has been done in the meantime to affect the existence of anything on the entire path.
--
-- Motions left or right are clamped, but all traversals included on the 'Tape' are assumed to be non-empty.
--
-- Violate these assumptions at your own risk!
unsafelyRestoreTrack :: Track h a -> Zipped h a -> h :> a
unsafelyRestoreTrack Track = zipper
unsafelyRestoreTrack (Fork h n l) = unsafelyRestoreTrack h >>> tugs right n >>> fromWithin l

-----------------------------------------------------------------------------
-- * Helper functions
-----------------------------------------------------------------------------

-- | Reverse a list.
--
-- GHC doesn't optimize @reverse []@ into @[]@, so we'll nudge it with our own
-- reverse function.
--
-- This is relevant when descending into a lens, for example -- we know the
-- unzipped part of the level will be empty.
reverseList :: [a] -> [a]
reverseList [] = []
reverseList (x:xs) = go [x] xs
  where
    go a [] = a
    go a (y:ys) = go (y:a) ys
{-# INLINE reverseList #-}
