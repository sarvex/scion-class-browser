{-# LANGUAGE RankNTypes, ImpredicativeTypes, ScopedTypeVariables #-}

module Scion.PersistentHoogle.Parser where

import Data.List (intercalate)
import qualified Data.Text as T
import Database.Persist
import Database.Persist.Sql
import Language.Haskell.Exts.Annotated.Syntax
import Scion.PersistentBrowser.DbTypes
import Scion.PersistentBrowser.Parser.Internal
import Scion.PersistentBrowser.Query
import Scion.PersistentBrowser.Types
import Scion.PersistentHoogle.Types
import Text.Parsec.Char
import Text.Parsec.Combinator
import Text.Parsec.Prim

data HalfResult = HalfPackage  String
                | HalfModule   String (Documented Module)
                | HalfDecl     String (Documented Decl)
                | HalfGadtDecl String (Documented GadtDecl)
                | HalfKeyword  String
                | HalfWarning  String -- ^ a warning

hoogleElements :: BSParser (SQL [Result])
hoogleElements = do elts <- hoogleElements'
                    let results = catMaybesM $ map convertHalfToResult elts
                    return results

catMaybesM :: Monad m => [m (Maybe a)] -> m [a]
catMaybesM []     = return []
catMaybesM (x:xs) = do y <- x
                       zs <- catMaybesM xs
                       case y of
                         Nothing -> return zs
                         Just z  -> return (z:zs)

hoogleElements' :: BSParser [HalfResult]
hoogleElements' =   try (do spaces0
                            optional $ try (do 
                                string "No results found"
                                spacesOrEol0)
                            eof
                            return [])
                <|> (do first <- hoogleElement
                        rest <- many $ try (try eol >> try hoogleElement)
                        spaces
                        eof
                        return $ first:rest)

hoogleElement :: BSParser HalfResult
hoogleElement =   try (do pname <- hooglePackageName
                          return $ HalfPackage pname)
              <|> try (do pname <- hoogleKeyword
                          return $ HalfKeyword pname)
              <|> try (do (mname, m) <- moduled (module_ NoDoc)
                          return $ HalfModule mname m)
              <|> try (do (mname, d) <- moduled (function NoDoc)
                          return $ HalfDecl mname d)
              <|> try (do (mname, d) <- moduled (dataHead NoDoc)
                          return $ HalfDecl mname d)
              <|> try (do (mname, d) <- moduled (newtypeHead NoDoc)
                          return $ HalfDecl mname d)
              <|> try (do (mname, d) <- moduled (type_ NoDoc)
                          return $ HalfDecl mname d)
              <|> try (do (mname, d) <- moduled (class_ NoDoc)
                          return $ HalfDecl mname d)
              <|> try (do (mname, d) <- moduled (constructor NoDoc)
                          return $ HalfGadtDecl mname d)
              <|> try (do 
                        string "Warning:"
                        spaces0
                        s<-restOfLine
                        return $ HalfWarning s)

moduled :: BSParser a -> BSParser (String, a)
moduled p = try (do mname <- try conid `sepBy` char '.'
                    let name = intercalate "." (map getid mname)
                    try spaces1
                    rest <- p
                    return (name, rest))

hooglePackageName :: BSParser String
hooglePackageName = string "package" >> restIsName

-- | handle a keyword. For example searching for 'id' gives 'keyword hiding' in the results
hoogleKeyword :: BSParser String
hoogleKeyword = string "keyword" >> restIsName

-- | Rest of the line is a name
restIsName :: BSParser String
restIsName = do 
  spaces1
  name <- restOfLine
  spaces0
  return name
                   
convertHalfToResult :: HalfResult -> SQL (Maybe Result)
convertHalfToResult (HalfKeyword kw) =
  return $ Just (RKeyword kw)
convertHalfToResult (HalfWarning w) =
  return $ Just (RWarning w)
convertHalfToResult (HalfPackage  pname) = 
  do pkgs <- packagesByName pname Nothing
     case pkgs of
       [] -> return Nothing
       p  -> return $ Just (RPackage p)
convertHalfToResult (HalfModule mname _) =
  do let sql = "SELECT DbModule.name, DbModule.doc, DbModule.packageId, DbPackage.name, DbPackage.version"
               ++ " FROM DbModule, DbPackage"
               ++ " WHERE DbModule.packageId = DbPackage.id"
               ++ " AND DbModule.name = ?"
     mods <- queryDb sql [mname] action
     return $ if null mods then Nothing else Just (RModule mods)
  where action [PersistText modName, modDoc, PersistInt64 pkgId, PersistText pkgName, PersistText pkgVersion] =
          ( DbPackageIdentifier (T.unpack pkgName) (T.unpack pkgVersion)
          , DbModule (T.unpack modName) (fromDbText modDoc) (DbPackageKey $ SqlBackendKey pkgId) )
        action _ = error "This should not happen"
convertHalfToResult (HalfDecl mname dcl) =
  do let sql = "SELECT DbDecl.id, DbDecl.declType, DbDecl.name, DbDecl.doc, DbDecl.kind, DbDecl.signature, DbDecl.equals, DbDecl.moduleId"
               ++ ", DbPackage.name, DbPackage.version"
               ++ " FROM DbDecl, DbModule, DbPackage"
               ++ " WHERE DbDecl.moduleId = DbModule.id"
               ++ " AND DbModule.packageId = DbPackage.id"
               ++ " AND DbDecl.name = ?"
               ++ " AND DbModule.name = ?"
     decls <- queryDb sql [getName dcl, mname] action
     completeDecls <- mapM (\(pkgId, modName, dclKey, dclInfo) -> do complete <- getAllDeclInfo (dclKey, dclInfo)
                                                                     return (pkgId, modName, complete) ) decls
     return $ if null completeDecls then Nothing else Just (RDeclaration completeDecls)
  where action [ PersistInt64 declId, PersistText declType, PersistText declName
               , declDoc, declKind, declSignature, declEquals, PersistInt64 modId
               , PersistText pkgName, PersistText pkgVersion ] =
               let (innerDclKey :: DbDeclId) = DbDeclKey $ SqlBackendKey declId
                   innerDcl = DbDecl (read (T.unpack declType)) (T.unpack declName) (fromDbText declDoc)
                                     (fromDbText declKind) (fromDbText declSignature) (fromDbText declEquals)
                                     (DbModuleKey $ SqlBackendKey modId)
               in ( DbPackageIdentifier (T.unpack pkgName) (T.unpack pkgVersion)
                  , mname
                  , innerDclKey
                  , innerDcl
                  )
        action _ = error "This should not happen"
convertHalfToResult (HalfGadtDecl mname dcl) =
  do let sql = "SELECT DbConstructor.name, DbConstructor.signature"
               ++ ", DbDecl.id, DbDecl.declType, DbDecl.name, DbDecl.doc, DbDecl.kind, DbDecl.signature, DbDecl.equals, DbDecl.moduleId"
               ++ ", DbPackage.name, DbPackage.version"
               ++ " FROM DbConstructor, DbDecl, DbModule, DbPackage"
               ++ " WHERE DbConstructor.declId = DbDecl.id" 
               ++ " AND DbDecl.moduleId = DbModule.id"
               ++ " AND DbModule.packageId = DbPackage.id"
               ++ " AND DbDecl.name = ?"
               ++ " AND DbModule.name = ?"
     decls <- queryDb sql [getName dcl, mname] action
     completeDecls <- mapM (\(pkgId, modName, dclKey, dclInfo, cst) -> do complete <- getAllDeclInfo (dclKey, dclInfo)
                                                                          return (pkgId, modName, complete, cst) ) decls
     return $ if null completeDecls then Nothing else Just (RConstructor completeDecls)
  where action [ PersistText constName, PersistText constSignature
               , PersistInt64 declId, PersistText declType, PersistText declName
               , declDoc, declKind, declSignature, declEquals, PersistInt64 modId
               , PersistText pkgName, PersistText pkgVersion ] =
               let (innerDclKey :: DbDeclId) = DbDeclKey $ SqlBackendKey declId
                   innerDcl = DbDecl (read (T.unpack declType)) (T.unpack declName) (fromDbText declDoc)
                                     (fromDbText declKind) (fromDbText declSignature) (fromDbText declEquals)
                                     (DbModuleKey $ SqlBackendKey modId)
               in ( DbPackageIdentifier (T.unpack pkgName) (T.unpack pkgVersion)
                  , mname
                  , innerDclKey
                  , innerDcl
                  , DbConstructor (T.unpack constName) (T.unpack constSignature) (DbDeclKey $ SqlBackendKey declId)
                  )
        action _ = error "This should not happen"

