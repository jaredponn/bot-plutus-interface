{-# LANGUAGE AllowAmbiguousTypes #-}

module MLabsPAB.PreBalance (
  preBalanceTx,
  preBalanceTxIO,
) where

import Control.Monad (foldM, zipWithM)
import Control.Monad.Freer (Eff, Member)
import Control.Monad.Trans.Class (lift)
import Control.Monad.Trans.Either (EitherT, hoistEither, newEitherT, runEitherT)
import Data.Either.Combinators (rightToMaybe)
import Data.Kind (Type)
import Data.List (partition, (\\))
import Data.Map (Map)
import Data.Map qualified as Map
import Data.Maybe (fromMaybe, mapMaybe)
import Data.Set (Set)
import Data.Set qualified as Set
import Data.Text (Text)
import Data.Text qualified as Text
import Ledger qualified
import Ledger.Ada qualified as Ada
import Ledger.Address (Address (..))
import Ledger.Constraints.OffChain (UnbalancedTx (..))
import Ledger.Crypto (PrivateKey, PubKeyHash)
import Ledger.Tx (
  Tx (..),
  TxIn (..),
  TxInType (..),
  TxOut (..),
  TxOutRef (..),
 )
import Ledger.Tx qualified as Tx
import Ledger.Value (Value (Value), getValue)
import Ledger.Value qualified as Value
import MLabsPAB.CardanoCLI qualified as CardanoCLI
import MLabsPAB.Effects (PABEffect, printLog)
import MLabsPAB.Files qualified as Files
import MLabsPAB.Types (LogLevel (Debug), PABConfig)
import Plutus.V1.Ledger.Api (
  Credential (PubKeyCredential, ScriptCredential),
  CurrencySymbol (..),
  TokenName (..),
 )
import PlutusTx.AssocMap qualified as AssocMap
import Prelude

{- | Collect necessary tx inputs and collaterals, add minimum lovelace values and balance non ada
 assets
-}
preBalanceTxIO ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  PABConfig ->
  PubKeyHash ->
  UnbalancedTx ->
  Eff effs (Either Text Tx)
preBalanceTxIO pabConf ownPkh unbalancedTx =
  runEitherT $
    do
      utxos <- lift $ CardanoCLI.utxosAt @w pabConf $ Ledger.pubKeyHashAddress ownPkh
      privKeys <- newEitherT $ Files.readPrivateKeys @w pabConf
      let utxoIndex = fmap Tx.toTxOut utxos <> unBalancedTxUtxoIndex unbalancedTx
          tx = unBalancedTxTx unbalancedTx
          requiredSigs = Map.keys (unBalancedTxRequiredSignatories unbalancedTx)

      lift $ printLog @w Debug $ show utxoIndex

      loop utxoIndex privKeys requiredSigs [] tx
  where
    loop ::
      Map TxOutRef TxOut ->
      Map PubKeyHash PrivateKey ->
      [PubKeyHash] ->
      [(TxOut, Integer)] ->
      Tx ->
      EitherT Text (Eff effs) Tx
    loop utxoIndex privKeys requiredSigs prevMinUtxos tx = do
      nextMinUtxos <-
        newEitherT $
          calculateMinUtxos @w pabConf $ Tx.txOutputs tx \\ map fst prevMinUtxos

      let minUtxos = prevMinUtxos ++ nextMinUtxos

      lift $ printLog @w Debug $ "Min utxos: " ++ show minUtxos

      txWithoutFees <-
        hoistEither $ preBalanceTx minUtxos 0 utxoIndex ownPkh privKeys requiredSigs tx

      lift $ CardanoCLI.buildTx @w pabConf ownPkh (CardanoCLI.BuildRaw 0) txWithoutFees
      fees <- newEitherT $ CardanoCLI.calculateMinFee @w pabConf txWithoutFees

      lift $ printLog @w Debug $ "Fees: " ++ show fees

      balancedTx <- hoistEither $ preBalanceTx minUtxos fees utxoIndex ownPkh privKeys requiredSigs tx

      if balancedTx == tx
        then pure balancedTx
        else loop utxoIndex privKeys requiredSigs minUtxos balancedTx

calculateMinUtxos ::
  forall (w :: Type) (effs :: [Type -> Type]).
  Member (PABEffect w) effs =>
  PABConfig ->
  [TxOut] ->
  Eff effs (Either Text [(TxOut, Integer)])
calculateMinUtxos pabConf txOuts =
  zipWithM (fmap . (,)) txOuts <$> mapM (CardanoCLI.calculateMinUtxo @w pabConf) txOuts

preBalanceTx ::
  [(TxOut, Integer)] ->
  Integer ->
  Map TxOutRef TxOut ->
  PubKeyHash ->
  Map PubKeyHash PrivateKey ->
  [PubKeyHash] ->
  Tx ->
  Either Text Tx
preBalanceTx minUtxos fees utxos ownPkh privKeys requiredSigs tx =
  addTxCollaterals utxos tx
    >>= balanceTxIns utxos fees
    >>= balanceNonAdaOuts ownPkh utxos
    >>= Right . addLovelaces minUtxos
    >>= balanceTxIns utxos fees -- Adding more inputs if required
    >>= balanceNonAdaOuts ownPkh utxos
    >>= addSignatories ownPkh privKeys requiredSigs

-- | Getting the necessary utxos to cover the fees for the transaction
collectTxIns :: Set TxIn -> Map TxOutRef TxOut -> Value -> Either Text (Set TxIn)
collectTxIns originalTxIns utxos value =
  if isSufficient updatedInputs
    then Right updatedInputs
    else
      Left $
        Text.unlines
          [ "Insufficient tx inputs, needed: "
          , showText (Value.flattenValue value)
          , "got:"
          , showText (Value.flattenValue (txInsValue updatedInputs))
          ]
  where
    updatedInputs =
      foldl
        ( \acc txIn ->
            if isSufficient acc
              then acc
              else Set.insert txIn acc
        )
        originalTxIns
        $ mapMaybe (rightToMaybe . txOutToTxIn) $ Map.toList utxos

    isSufficient :: Set TxIn -> Bool
    isSufficient txIns' =
      not (Set.null txIns') && txInsValue txIns' `Value.geq` value

    txInsValue :: Set TxIn -> Value
    txInsValue txIns' =
      mconcat $ map Tx.txOutValue $ mapMaybe ((`Map.lookup` utxos) . Tx.txInRef) $ Set.toList txIns'

-- Converting a chain index transaction output to a transaction input type
txOutToTxIn :: (TxOutRef, TxOut) -> Either Text TxIn
txOutToTxIn (txOutRef, txOut) =
  case addressCredential (txOutAddress txOut) of
    PubKeyCredential _ -> Right $ Tx.pubKeyTxIn txOutRef
    ScriptCredential _ -> Left "Cannot covert a script output to TxIn"

-- | Add min lovelaces to each tx output
addLovelaces :: [(TxOut, Integer)] -> Tx -> Tx
addLovelaces minLovelaces tx =
  let lovelacesAdded =
        map
          ( \txOut ->
              let outValue = txOutValue txOut
                  lovelaces = Ada.getLovelace $ Ada.fromValue outValue
                  minUtxo = fromMaybe 0 $ lookup txOut minLovelaces
               in txOut
                    { txOutValue =
                        outValue <> Ada.lovelaceValueOf (max 0 (minUtxo - lovelaces))
                    }
          )
          $ txOutputs tx
   in tx {txOutputs = lovelacesAdded}

balanceTxIns :: Map TxOutRef TxOut -> Integer -> Tx -> Either Text Tx
balanceTxIns utxos fees tx = do
  let txOuts = Tx.txOutputs tx
      nonMintedValue = mconcat (map Tx.txOutValue txOuts) `minus` txMint tx
      minSpending =
        mconcat
          [ Ada.lovelaceValueOf fees
          , nonMintedValue
          ]
  txIns <- collectTxIns (txInputs tx) utxos minSpending
  pure $ tx {txInputs = txIns <> txInputs tx}

{- | Pick a collateral from the utxo map and add it to the unbalanced transaction
 (suboptimally we just pick a random utxo from the tx inputs)
-}
addTxCollaterals :: Map TxOutRef TxOut -> Tx -> Either Text Tx
addTxCollaterals utxos tx = do
  let txIns = mapMaybe (rightToMaybe . txOutToTxIn) $ Map.toList utxos
  txIn <- findPubKeyTxIn txIns
  pure $ tx {txCollateral = Set.singleton txIn}
  where
    findPubKeyTxIn = \case
      x@(TxIn _ (Just ConsumePublicKeyAddress)) : _ -> Right x
      x@(TxIn _ Nothing) : _ -> Right x
      _ : xs -> findPubKeyTxIn xs
      _ -> Left "There are no utxos to be used as collateral"

-- | We need to balance non ada values, as the cardano-cli is unable to balance them (as of 2021/09/24)
balanceNonAdaOuts :: PubKeyHash -> Map TxOutRef TxOut -> Tx -> Either Text Tx
balanceNonAdaOuts ownPkh utxos tx =
  let changeAddr = Ledger.pubKeyHashAddress ownPkh
      txInRefs = map Tx.txInRef $ Set.toList $ txInputs tx
      inputValue = mconcat $ map Tx.txOutValue $ mapMaybe (`Map.lookup` utxos) txInRefs
      outputValue = mconcat $ map Tx.txOutValue $ txOutputs tx
      nonMintedOutputValue = outputValue `minus` txMint tx
      nonAdaChange = filterNonAda inputValue `minus` filterNonAda nonMintedOutputValue
      outputs =
        case partition ((==) changeAddr . Tx.txOutAddress) $ txOutputs tx of
          ([], txOuts) ->
            TxOut
              { txOutAddress = changeAddr
              , txOutValue = nonAdaChange
              , txOutDatumHash = Nothing
              } :
            txOuts
          (txOut@TxOut {txOutValue = v} : txOuts, txOuts') ->
            txOut {txOutValue = v <> nonAdaChange} : (txOuts <> txOuts')
   in if isValueNat nonAdaChange
        then Right $ if Value.isZero nonAdaChange then tx else tx {txOutputs = outputs}
        else Left "Not enough inputs to balance tokens."

{- | Add the required signatorioes to the transaction. Be aware the the signature itself is invalid,
 and will be ignored. Only the pub key hashes are used, mapped to signing key files on disk.
-}
addSignatories :: PubKeyHash -> Map PubKeyHash PrivateKey -> [PubKeyHash] -> Tx -> Either Text Tx
addSignatories ownPkh privKeys pkhs tx =
  foldM
    ( \tx' pkh ->
        case Map.lookup pkh privKeys of
          Just privKey -> Right $ Tx.addSignature privKey tx'
          Nothing -> Left "Signing key not found."
    )
    tx
    (ownPkh : pkhs)

showText :: forall (a :: Type). Show a => a -> Text
showText = Text.pack . show

-- | Filter by key for Associated maps (why doesn't this exist?)
filterKey :: (k -> Bool) -> AssocMap.Map k v -> AssocMap.Map k v
filterKey f = AssocMap.mapMaybeWithKey $ \k v -> if f k then Just v else Nothing

-- | Filter a value to contain only non ada assets
filterNonAda :: Value -> Value
filterNonAda = Value . filterKey (/= Ada.adaSymbol) . getValue

minus :: Value -> Value -> Value
minus x y =
  let negativeValues = map (\(c, t, a) -> (c, t, - a)) $ Value.flattenValue y
   in x <> mconcat (map unflattenValue negativeValues)

unflattenValue :: (CurrencySymbol, TokenName, Integer) -> Value
unflattenValue (curSymbol, tokenName, amount) =
  Value.assetClassValue (Value.assetClass curSymbol tokenName) amount

isValueNat :: Value -> Bool
isValueNat =
  all (\(_, _, a) -> a >= 0) . Value.flattenValue
