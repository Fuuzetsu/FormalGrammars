{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE RecordWildCards #-}
{- LANGUAGE OverloadedStrings #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE NoMonomorphismRestriction #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

-- | We define a simple domain-specific language for context-free languages.

module FormalLanguage.Parser where

import           Control.Applicative
import           Control.Arrow
import           Control.Lens
import           Control.Monad.Identity
import           Control.Monad.State.Class (MonadState (..))
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.State.Strict hiding (get)
import           Data.Default
import           Data.Either
import           Data.List (partition,sort,nub)
import           Data.Maybe (catMaybes,isJust)
import qualified Data.ByteString.Char8 as B
import qualified Data.HashSet as H
import qualified Data.Map as M
import qualified Data.Set as S
import           Text.Parser.Expression
import           Text.Parser.Token.Highlight
import           Text.Parser.Token.Style
import           Text.Printf
import           Text.Trifecta
import           Text.Trifecta.Delta
import           Text.Trifecta.Result

import Debug.Trace

import FormalLanguage.Grammar



data Enumerated
  = Sing
  | ZeroBased Integer
  | Enum      [String]
  deriving (Show)

-- | The 

data GrammarState = GrammarState
  { _nsys         :: M.Map String Enumerated
  , _tsys         :: S.Set String
  , _esys         :: S.Set String
  , _grammarNames :: S.Set String
  }
  deriving (Show)

instance Default GrammarState where
  def = GrammarState
          { _nsys = def
          , _tsys = def
          , _esys = def
          , _grammarNames = def
          }

makeLenses ''GrammarState

-- | Parse a single grammar.

grammar :: Parse Grammar
grammar = do
  reserveGI "Grammar:"
  name :: String <- identGI
  (_nsyms,_tsyms) <- ((S.fromList *** S.fromList) . partitionEithers . concat)
                  <$> some (map Left <$> nts <|> map Right <$> ts)
  _epsis <- S.fromList <$> many epsP
  _start <- try (Just <$> startSymbol) <|> pure Nothing
  _rules <- (S.fromList . concat) <$> some rule
  reserveGI "//"
  grammarNames <>= S.singleton name
  return Grammar { .. }

-- | Start symbol. Only a single symbol may be given
--
-- TODO for indexed symbols make sure we actually have one index to start with.

startSymbol :: Parse Symb
startSymbol = do
  reserveGI "S:"
  name :: String <- identGI
  -- TODO go and allow indexed NTs as start symbols, with one index given
  -- return $ nsym1 name Singular
  return $ Symb [N name Singular]

-- | The non-terminal declaration "NT: ..." returns a list of non-terms as
-- indexed non-terminals are expanded.

nts :: Parse [Symb]
nts = do
  reserveGI "N:"
  name   <- identGI
  enumed <- option Sing $ braces enumeration
  let zs = expandNT name enumed
  nsys <>= M.singleton name enumed
  return zs

-- | expand set of non-terminals based on type of enumerations

expandNT :: String -> Enumerated -> [Symb]
expandNT name = go where
  go Sing          = [Symb [N name Singular]]
  go (ZeroBased k) = [Symb [N name (IntBased   z [0..(k-1)])] | z <- [0..(k-1)]]
  go (Enum es)     = [Symb [N name (Enumerated z es        )] | z <- es        ]

-- | Figure out if we are dealing with indexed (enumerable) non-terminals

enumeration =   ZeroBased <$> natural
            <|> Enum      <$> sepBy1 identGI (string ",")

-- | Parse declared terminal symbols.

ts :: Parse [Symb]
ts = do
  reserveGI "T:"
  n <- identGI
  let z = Symb [T n]
  tsys <>= S.singleton n
  return [z]

-- | Parse epsilon symbols

epsP :: Parse TN
epsP = do
  reserveGI "E:"
  e <- identGI
  esys <>= S.singleton e
  return $ E e

-- | Parse a single rule. Some rules come attached with an index. In that case,
-- each rule is inflated according to its modulus (or more general the set of
-- indices indicated.
--
-- TODO add @fun@ to each PR
--
-- TODO expand NT on left-hand side with all variants based on index.
--
-- TODO allow multidimensional rules ...
--
-- TODO handle epsilons on both sides correctly (but do not allow
-- ``only-epsilon'' NTs)
--
-- BAUSTELLE: the first step lhsN tells us if we have an indexed system {i}, on
-- the rhs we then have stuff a la {i+1}. This needs to be done correctly ...

rule :: Parse [Rule]
rule = do
  lhs <- lhsPreNonTerminal
  reserveGI "->"
  fun :: String <- identGI
  reserveGI "<<<"
  -- zs <- fmap sequence . runUnlined $ some (try ruleNts <|> try ruleTs) -- expand zs to all production rules
  rhs <- runUnlined $ some (try rhsPreNonTerminal <|> try rhsPreTerminal)
  whiteSpace
  -- let lhs = map (\(z,_) -> N z Singular) lhsN -- TODO tag epsilons as epsilons
  s <- get
  let r = generateRules s lhs rhs
  error $ show (lhs,rhs,r)
  return undefined -- [Rule (Symb lhs) [fun] z | z <- zs]

-- | Actually create a rule given both lhs and rhs. This means we need to
-- expand rules according to what we allow.
--
-- TODO what about X -> Y{i} ? This should expand to X -> Y{0} | Y{1}
--
-- TODO X{i} -> Y{i} => X{0} -> Y{0} ; X{1} -> Y{1}
--
-- TODO X{i}->Y{j} => X{0}->Y{0}|Y{1} ; X{1}->Y{0}|Y{1}

generateRules :: GrammarState -> [(String,Maybe String)] -> [PreSymb] -> ()
generateRules s lhs rhs = error $ show (is) where
  is :: M.Map String String -- this gives us all indices (as a map from the index name to the corresponding non-terminal
  is = M.fromList $ [ (i,n) | (n,Just i) <- lhs ]

-- | Parse the lhs symbol together with all indices (for each individual
-- non-terminal).
--
-- TODO confirm that indexed non-terminals are actually indexable

lhsPreNonTerminal :: P m => m [(String,Maybe String)]
lhsPreNonTerminal = do
  let iigi = (,) <$> identGI <*> option Nothing (try $ Just <$> braces identGI) -- indexed ident GI
  ns <- (:[]) <$> iigi <|> list iigi <?> "requires non-terminal here"
  nsys `uses` (\z -> or  [M.member    y z | (y,_) <- ns]) >>= guard
    <?> "at least one non-terminal symbol required"
  esys `uses` (\z -> and [S.notMember y z | (y,Just _) <- ns]) >>= guard
    <?> "indexed epsilon encountered"
  tsys `uses` (\z -> and [S.notMember y z | (y,_) <- ns]) >>= guard
    <?> "no terminal symbols allowed"
  let xs = ns^..folded._2.traverse
  guard (sort xs == sort (nub xs)) <?> "repeated index on lhs"
  return ns

data PreSymb
  = PreN [(String, Maybe String)]
  | PreT [String]
  deriving (Show)

-- |
--
-- TODO all error handling is currently missing

--rhsPreNonTerminal :: U m => m PreSymb -- [(String,Maybe String)]
rhsPreNonTerminal = do
  let iigi = (,) <$> identGI <*> option Nothing (try $ Just <$ string "{" <*> manyTill anyChar (try $ string "}"))
  ns <- (:[]) <$> iigi <|> list iigi <?> "requires non-terminal here"
  -- TODO correctness checking
  return $ PreN ns

-- |
--
-- TODO need to handle ``either terminal or epsilon''

--rhsPreTerminal :: U m => m PreSymb -- [String]
rhsPreTerminal = do
  ts <- (:[]) <$> identGI <|> list identGI <?> "rule: terminal identifier"
  lift $ tsys `uses` (\z -> or [S.member y z | y <- ts]) >>= guard <?> (printf "undeclared T: %s" $ show ts)
  -- lift $ nsys `uses` (M.notMember n) >>= guard <?> (printf "used non-terminal in T role: %s" n)
  return $ PreT ts

-- | Parses a list of a la @[a,b,c]@

list = brackets . commaSep

-- | Parse non-terminal symbols in production rules. If we have an indexed
-- non-terminal, more than one result will be returned.
--
-- TODO expand with indexed version

ruleNts :: ParseU [Symb] -- (String,NtIndex)
ruleNts = do
  n <- identGI <?> "rule: nonterminal identifier"
--  i <- nTindex <?> "rule:" -- option ("",1) $ braces ((,) <$> ident gi <*> option 0 integer) <?> "rule: nonterminal index"
  lift $ nsys `uses` (M.member n   ) >>= guard <?> (printf "undeclared NT: %s" n)
  lift $ tsys `uses` (S.notMember n) >>= guard <?> (printf "used terminal in NT role: %s" n)
  return [Symb [N n Singular]] -- [nsym1 n Singular] -- (n,i)

-- | Parse terminal symbols in production rules. Returns singleton list of
-- terminal.

ruleTs :: ParseU [Symb]
ruleTs = do
  n <- identGI <?> "rule: terminal identifier"
  lift $ tsys `uses` (S.member n   ) >>= guard <?> (printf "undeclared T: %s" n)
  lift $ nsys `uses` (M.notMember n) >>= guard <?> (printf "used non-terminal in T role: %s" n)
  return [Symb [T n]] -- [TSym [n]]

-- * Monadic Parsing Machinery

-- | Parser with 'GrammarState'

newtype GrammarParser m a = GrammarP { runGrammarP :: StateT GrammarState m a }
  deriving  ( Monad
            , MonadPlus
            , Alternative
            , Applicative
            , Functor
            , MonadState GrammarState
            , TokenParsing
            , CharParsing
            , Parsing
            , MonadTrans
            )

-- | Functions that parse using the 'GrammarParser'

type Parse  a = ( Monad m
                , MonadPlus m
                , TokenParsing m
                ) => GrammarParser m a

-- | Parsing where we stop at a newline (which needs to be parsed explicitly)

type ParseU a = (Monad m
                , MonadPlus m
                , TokenParsing m
                ) => Unlined (GrammarParser m) a

type P m = ( Monad m
           , MonadPlus m
           , Alternative m
           , Parsing m
           , TokenParsing m
           , MonadState GrammarState m
           )

-- | grammar identifiers

grammarIdentifiers = set styleReserved rs emptyIdents where
  rs = H.fromList ["Grammar:", "N:", "T:", "E:"]

-- | partial binding of 'reserve' to idents

reserveGI = reserve grammarIdentifiers

identGI = ident grammarIdentifiers



--
-- test stuff
--

testGrammar = unlines
  [ "Grammar: Align"
  , "N: X"
  , "T: a"
  , "E: epsilon"
  , "E: ε"
  , "S: X"
  , "[X{i}] -> many <<< [X{i}]"
--  , "X -> step  <<< X a"
--  , "X -> stand <<< X"
--  , "[X] -> oned <<< [X]"
--  , "X -> eps   <<< epsilon"
  , "//"
  ]

testParsing :: Result Grammar
testParsing = parseString
                ((evalStateT . runGrammarP) grammar def)
                (Directed (B.pack "testGrammar") 0 0 0 0)
                testGrammar

asG = let (Success g) = testParsing in g
