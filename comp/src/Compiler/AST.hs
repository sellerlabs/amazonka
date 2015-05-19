{-# LANGUAGE FlexibleContexts  #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TupleSections     #-}
{-# LANGUAGE TypeOperators     #-}

-- Module      : Compiler.AST
-- Copyright   : (c) 2013-2015 Brendan Hay <brendan.g.hay@gmail.com>
-- License     : This Source Code Form is subject to the terms of
--               the Mozilla Public License, v. 2.0.
--               A copy of the MPL can be found in the LICENSE file or
--               you can obtain it at http://mozilla.org/MPL/2.0/.
-- Maintainer  : Brendan Hay <brendan.g.hay@gmail.com>
-- Stability   : experimental
-- Portability : non-portable (GHC extensions)

module Compiler.AST where

import           Compiler.AST.Cofree
import           Compiler.AST.Data
import           Compiler.AST.Prefix
import           Compiler.AST.Solve
import           Compiler.Formatting
import           Compiler.Override
import           Compiler.Protocol
import           Compiler.Types
import           Control.Error
import           Control.Lens
import           Control.Monad.Except (throwError)
import           Control.Monad.State
import qualified Data.Foldable        as Fold
import qualified Data.HashMap.Strict  as Map
import qualified Data.HashSet         as Set
import           Data.List            (sort)
import           Data.Monoid
import           Debug.Trace

-- Order:
-- substitute
-- recase
-- override
-- default
-- prefix
-- type

rewrite :: Versions
        -> Config
        -> Service Maybe (RefF ()) (ShapeF ())
        -> Either Error Library
rewrite v cfg s' = do
    -- Determine which direction (input, output, or both) shapes are used.
    rs <- relations (s' ^. operations) (s' ^. shapes)
        -- Apply the override configuration to the service, and default any
        -- optional fields from the JSON where needed.
    s  <- setDefaults rs (override (cfg ^. typeOverrides) s')
        -- Perform the necessary rewrites and rendering
        -- of shapes Haskell data declarations.
        >>= renderShapes rs cfg

    let ns     = NS ["Network", "AWS", s ^. serviceAbbrev]
        other  = cfg ^. operationImports ++ cfg ^. typeImports
        expose = ns
               : ns <> "Types"
               : ns <> "Waiters"
               : map (mappend ns)
                     (s ^.. operations . each . operationNS)

    return $! Library v cfg s ns (sort expose) (sort other)

renderShapes :: Map Id Relation
             -> Config
             -> Service Identity (RefF ()) (ShapeF ())
             -> Either Error (Service Identity Data Data)
renderShapes rs cfg svc = do
    (os, ss)
        -- Elaborate the map into a comonadic strucutre for traversing.
         <- elaborate (svc ^. shapes)
        -- Generate unique prefixes for struct (product) members and
        -- enum (sum) branches to avoid ambiguity.
        >>= prefixes
        -- Annotate the comonadic tree with the associated
        -- bi/unidirectional (input/output/both) relation for shapes
        >>= traverse (pure . attach rs)
        -- Determine the appropriate Haskell AST type, auto deriveable instances,
        -- and fully rendered instances.
        >>= pure . solve cfg (svc ^. protocol)
        -- Convert the shape AST into a rendered Haskell AST declaration
        >>= kvTraverseMaybe (const (dataType (svc ^. protocol) . fmap rassoc))
        -- Separate the operation input/output shapes from the .Types shapes.
        >>= separate (svc ^. operations)
    return $! svc
        { _operations = os
        , _shapes     = ss
        }

type MemoR = StateT (Map Id Relation) (Either Error)

-- FIXME:
-- Maybe make this more detailed and provide a map of which shapes are used
-- by which other shapes? This can be used to create
-- cross linked haddock markup like /See:/ Parent1, Parent2, etc.

-- | Determine the relation for operation payloads, both input and output.
--
-- /Note:/ This currently doesn't operate over the free AST, since it's also
--used by 'setDefaults'.
relations :: Map Id (Operation Maybe (RefF a))
          -> Map Id (ShapeF b)
          -> Either Error (Map Id Relation)
relations os ss = execStateT (traverse go os) mempty
  where
    go :: Operation Maybe (RefF a) -> MemoR ()
    go o = count (o ^. opName) Input  (o ^? opInput  . _Just . refShape)
        >> count (o ^. opName) Output (o ^? opOutput . _Just . refShape)

    -- | Inserts a valid relation containing an referring shape's id,
    -- and the direction the parent is used in.
    count :: Id -> Direction -> Maybe Id -> MemoR ()
    count _ _ Nothing  = pure ()
    count p d (Just n) = do
        modify (Map.insertWith (<>) n (relation p d))
        s <- lift $ note (format ("Unable to find shape " % iprimary %
                         " when counting relations") n)
                       (Map.lookup n ss)
        shape n d s

    shape :: Id -> Direction -> ShapeF a -> MemoR ()
    shape p d = mapM_ (count p d . Just . view refShape) . toListOf references

type Sep a = StateT (Map Id a) (Either Error)

-- | Filter the ids representing operation input/outputs from the supplied map,
-- attaching them to the appropriate operation.
separate :: Show b => Map Id (Operation Identity (RefF a))
         -> Map Id b
         -> Either Error (Map Id (Operation Identity b), Map Id b)
separate os ss = runStateT (traverse go os) ss
  where
    go :: Operation Identity (RefF a) -> Sep b (Operation Identity b)
    go o = do
        rq <- remove (o ^. input)
        rs <- remove (o ^. output)
        return $! o
            { _opInput  = Identity rq
            , _opOutput = Identity rs
            }

    remove :: Id -> Sep a a
    remove n = do
        s <- get
        case Map.lookup n s of
            Just x | n == textToId "ScalingProcessQuery"
                      -> modify (Map.delete n) >> trace ("Removed " ++ show n) (pure x)
                   | otherwise -> modify (Map.delete n) >> pure x
            Nothing -> throwError $
                format ("Failure attempting to remove operation wrapper " %
                       iprimary % " from " % partial)
                       n (n, Map.map (const ()) s)

type Subst = StateT (Map Id Override, Map Id (ShapeF ())) (Either Error)

-- | Set some appropriate defaults where needed for later stages,
-- and ensure there are no vacant references to input/output shapes
-- by adding any empty request or response types where appropriate.
setDefaults :: Map Id Relation
            -> Service Maybe (RefF ()) (ShapeF ())
            -> Either Error (Service Identity (RefF ()) (ShapeF ()))
setDefaults rs svc@Service{..} = do
    (os, (ovs, ss)) <-
        runStateT (traverse operation _operations) (mempty, _shapes)
    -- Apply any overrides that might have been returned for wrappers.
    return $! override ovs $ svc
        { _metadata'  = meta _metadata'
        , _operations = os
        , _shapes     = ss
        }
  where
    meta :: Metadata Maybe -> Metadata Identity
    meta m@Metadata{..} = m
        { _timestampFormat = _timestampFormat .! timestamp _protocol
        , _checksumFormat  = _checksumFormat  .! SHA256
        }

    operation :: Operation Maybe (RefF ())
              -> Subst (Operation Identity (RefF ()))
    operation o@Operation{..} = do
        rq <- subst (name Input  _opName) _opInput
        rs <- subst (name Output _opName) _opOutput
        return $! o
            { _opDocumentation =
                _opDocumentation .! "FIXME: Undocumented operation."
            , _opHTTP          = http _opHTTP
            , _opInput         = rq
            , _opOutput        = rs
            }

    http :: HTTP Maybe -> HTTP Identity
    http h = h
        { _responseCode = _responseCode h .! 200
        }

    -- FIXME: too complicated? Just copy the shape if it's shared, and since
    -- this is an operation, consider it safe to remove the shape wholly?

    -- Fill out missing Refs with a default Ref pointing to an empty Shape,
    -- which is also inserted into the resulting Shape universe.
    --
    -- Likewise provide an appropriate wrapper over any shared Shape.
    subst :: Id -> Maybe (RefF ()) -> Subst (Identity (RefF ()))
    subst n (Just r)
          -- Ref exists, and is not referred to by any other Shape.
        | not (Set.member (r ^. refShape) shared) = do
            -- Insert override to rename the Ref/Shape to the desired name.
            _1 %= Map.insert (r ^. refShape) (defaultOverride & renamedTo ?~ n)
            return $! Identity r

          -- Ref exists and is referred to by other shapes.
        | otherwise = do
            -- Check that the desired name is not in use
            -- to prevent accidental override.
            verify n "Failed attempting to create wrapper"
            -- Create a newtype wrapper which points to the shared Shape
            -- and has 'StructF.wrapper' set.
            _2 %= Map.insert n (emptyStruct (Map.singleton (r ^. refShape) r) True)
            -- Update the Ref to point to the new wrapper.
            return $! Identity (r & refShape .~ n)

    -- No Ref exists, safely insert an empty shape and return a related Ref.
    subst n Nothing  = do
        verify n "Failure attemptting to substitute fresh shape"
        _2 %= Map.insert n (emptyStruct mempty False)
        return $! Identity (emptyRef n)

    verify n msg = do
        p <- uses _2 (Map.member n)
        when p . throwError $
            format (msg % " for " % iprimary) n

    name :: Direction -> Id -> Id
    name Input  n = textToId (n ^. typeId)
    name Output n = textToId (appendId n "Response" ^. typeId)

    shared :: Set Id
    shared = sharing rs

    infixl 7 .!

    (.!) :: Maybe a -> a -> Identity a
    m .! x = maybe (Identity x) Identity m

    emptyStruct ms = Struct . StructF i ms (Set.fromList (Map.keys ms)) Nothing
      where
        i = Info
            { _infoDocumentation = Nothing
            , _infoMin           = Nothing
            , _infoMax           = Nothing
            , _infoFlattened     = False
            , _infoSensitive     = False
            , _infoStreaming     = False
            , _infoException     = False
            }

    emptyRef n = RefF
        { _refAnn           = ()
        , _refShape         = n
        , _refDocumentation = Nothing
        , _refLocation      = Nothing
        , _refLocationName  = Nothing
        , _refResultWrapper = Nothing
        , _refQueryName     = Nothing
        , _refStreaming     = False
        , _refXMLAttribute  = False
        , _refXMLNamespace  = Nothing
        }
