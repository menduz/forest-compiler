{-# LANGUAGE OverloadedStrings #-}
{-# OPTIONS -Wall #-}

module HaskellSyntax
  ( printExpression
  , printModule
  , parseModule
  , ParseError'
  , rws
  , s
  , expr
  ) where

import Language

import Control.Applicative (empty)
import Control.Monad (void)
import Data.Functor.Identity ()
import Data.List (intercalate)
import qualified Data.List.NonEmpty as NE
import Data.Semigroup
import Data.Text ()
import Data.Void (Void)

import Text.Megaparsec
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as L
import Text.Megaparsec.Expr

type Parser = Parsec Void String

type ParseError' = ParseError Char Void

lineComment :: Parser ()
lineComment = L.skipLineComment "#"

scn :: Parser ()
scn = L.space space1 lineComment empty

sc :: Parser ()
sc = L.space (void $ takeWhile1P Nothing f) lineComment empty
  where
    f x = x == ' ' || x == '\t'

lexeme :: Parser a -> Parser a
lexeme = L.lexeme sc

exprWithoutCall :: Parser Expression
exprWithoutCall = makeExprParser (lexeme termWithoutCall) table <?> "expression"

expr :: Parser Expression
expr = makeExprParser (lexeme term) table <?> "expression"

term :: Parser Expression
term = sc *> (try pCase <|> try pLet <|> parens <|> call <|> number <|> pString)

termWithoutCall :: Parser Expression
termWithoutCall =
  sc *>
  (try pCase <|> try pLet <|> parens <|> identifier <|> number <|> pString)

pString :: Parser Expression
pString = String' <$> between (string "\"") (string "\"") (many $ notChar '"')

symbol :: String -> Parser String
symbol = L.symbol sc

parens :: Parser Expression
parens = BetweenParens <$> between (symbol "(" *> scn) (scn <* symbol ")") expr

table :: [[Operator Parser Expression]]
table =
  [ [InfixL (Infix Divide <$ char '/')]
  , [InfixL (Infix Multiply <$ char '*')]
  , [InfixL (Infix StringAdd <$ symbol "++")]
  , [InfixL (Infix Add <$ char '+')]
  , [InfixL (Infix Subtract <$ char '-')]
  ]

number :: Parser Expression
number = Number <$> (sc *> L.decimal)

rws :: [String] -- list of reserved words
rws = ["case", "of", "let"]

pIdent :: Parser Ident
pIdent = (lexeme . try) (p >>= check)
  where
    p = (:) <$> letterChar <*> many alphaNumChar
    check x =
      if x `elem` rws
        then fail $ "keyword " ++ show x ++ " cannot be an identifier"
        else case NE.nonEmpty x of
               Just n -> return $ (Ident . NonEmptyString) n
               Nothing -> fail "identifier must be longer than zero characters"

pCase :: Parser Expression
pCase = L.indentBlock scn p
  where
    p = do
      _ <- symbol "case"
      sc
      caseExpr <- expr
      scn
      _ <- symbol "of"
      return $
        L.IndentSome Nothing (return . Case caseExpr . NE.fromList) caseBranch
    caseBranch = do
      sc
      pattern' <- number <|> identifier
      sc
      _ <- symbol "->"
      scn
      branchExpr <- expr
      return (pattern', branchExpr)

pLet :: Parser Expression
pLet = do
  declarations <- pDeclarations
  _ <- symbol "in"
  scn
  expression <- expr
  return $ Let declarations expression
  where
    pDeclarations = L.indentBlock scn p
    p = do
      _ <- symbol "let"
      return $ L.IndentSome Nothing (return . NE.fromList) declaration

call :: Parser Expression
call = do
  name <- pIdent
  args <- many (try exprWithoutCall)
  return $
    case length args of
      0 -> Identifier name
      _ -> Call name args

identifier :: Parser Expression
identifier = Identifier <$> pIdent

tld :: Parser TopLevel
tld = L.nonIndented scn (dataType <|> function)

dataType :: Parser TopLevel
dataType = do
  _ <- symbol "data"
  name <- pIdent
  generics <- many pIdent
  scn
  _ <- symbol "="
  constructor <- pConstructor
  constructors <- many (try (scn *> symbol "|" *> sc *> pConstructor))
  scn
  return $
    DataType $ ADT name generics (NE.fromList (constructor : constructors))
  where
    pConstructor = do
      name <- pIdent
      types <- many pIdent
      return $ Constructor name types

function :: Parser TopLevel
function = Function <$> declaration

declaration :: Parser Declaration
declaration = do
  annotation' <- maybeParse annotation
  sc
  name <- pIdent
  args <- many (try (sc *> pIdent))
  sc
  _ <- symbol "="
  scn
  expression <- expr
  scn
  return $ Declaration annotation' name args expression
  where
    annotation = do
      name <- pIdent
      sc
      _ <- symbol "::"
      sc
      firstType <- pIdent
      types <- many pType
      scn
      return $ Annotation name (NE.fromList $ firstType : types)
    pType = do
      _ <- symbol "->"
      sc
      pIdent

maybeParse :: Parser a -> Parser (Maybe a)
maybeParse parser = (Just <$> try parser) <|> Nothing <$ symbol "" -- TODO fix symbol "" hack

parseModule :: String -> Either ParseError' Module
parseModule = parse pModule ""
  where
    pModule = Module <$> many tld <* eof

printModule :: Module -> String
printModule (Module topLevel) = intercalate "\n\n" $ map printTopLevel topLevel

printTopLevel :: TopLevel -> String
printTopLevel topLevel =
  case topLevel of
    Function declaration' -> printDeclaration declaration'
    DataType dataType' -> printDataType dataType'

printDataType :: ADT -> String
printDataType (ADT name generics constructors) =
  "data " ++
  unwords (s <$> name : generics) ++
  "\n" ++
  indent2
    ("= " ++
     (intercalate "\n| " . NE.toList) (printConstructor <$> constructors))
  where
    printConstructor (Constructor name' types) = unwords $ s <$> (name' : types)

printDeclaration :: Declaration -> String
printDeclaration (Declaration annotation name args expr') =
  annotationAsString <> unwords ([s name] <> (s <$> args) <> ["="]) ++
  "\n" ++ indent2 (printExpression expr')
  where
    annotationAsString = maybe "" printAnnotation annotation

printAnnotation :: Annotation -> String
printAnnotation (Annotation name types) =
  s name <> " :: " <> intercalate " -> " (NE.toList $ s <$> types) <> "\n"

printExpression :: Expression -> String
printExpression expression =
  case expression of
    Number n -> show n
    Infix op expr' expr'' ->
      unwords
        [printExpression expr', operatorToString op, printSecondInfix expr'']
    Identifier name -> s name
    Call name args -> s name ++ " " ++ unwords (printExpression <$> args)
    Case caseExpr patterns ->
      if isComplex caseExpr
        then "case\n" ++
             indent2 (printExpression caseExpr) ++
             "\nof\n" ++ indent2 (printPatterns patterns)
        else "case " ++
             printExpression caseExpr ++
             " of\n" ++ indent2 (printPatterns patterns)
    BetweenParens expr' ->
      if isComplex expr'
        then "(\n" ++ indent2 (printExpression expr') ++ "\n)"
        else "(" ++ printExpression expr' ++ ")"
    Let declarations expr' -> printLet declarations expr'
    String' str -> "\"" ++ str ++ "\""
  where
    printPatterns patterns = unlines $ NE.toList $ printPattern <$> patterns
    printPattern (patternExpr, resultExpr) =
      printExpression patternExpr ++ " -> " ++ printSecondInfix resultExpr
    printLet declarations expr' =
      intercalate "\n" $
      concat
        [ ["let"]
        , indent2 . printDeclaration <$> NE.toList declarations
        , ["in"]
        , [indent2 $ printExpression expr']
        ]
    printSecondInfix expr' =
      if isComplex expr'
        then "\n" ++ indent2 (printExpression expr')
        else printExpression expr'

isComplex :: Expression -> Bool
isComplex expr' =
  case expr' of
    Let {} -> True
    Case {} -> True
    Infix _ a b -> isComplex a || isComplex b
    _ -> False

indent :: Int -> String -> String
indent level str =
  intercalate "\n" $ map (\line -> replicate level ' ' ++ line) (lines str)

indent2 :: String -> String
indent2 = indent 2

operatorToString :: OperatorExpr -> String
operatorToString op =
  case op of
    Add -> "+"
    Subtract -> "-"
    Multiply -> "*"
    Divide -> "/"
    StringAdd -> "++"
--  DataType name constructors ->
