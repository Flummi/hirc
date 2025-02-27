{-# LANGUAGE DeriveAnyClass #-}
{-# LANGUAGE ImportQualifiedPost #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS -fno-warn-incomplete-patterns #-}

module Hirc.Modules.Poker
  ( pokerModule,
  )
where

import Control.Concurrent.STM (atomically, catchSTM, modifyTVar, readTVar, throwSTM, writeTVar)
import Control.Concurrent.STM qualified as STM
import Control.Exception.Peel (Exception, SomeException (SomeException), catch, handle, throw)
import Control.Monad (forM, forM_, guard, join, liftM, mzero, unless, when)
import Control.Monad.Error.Class (MonadError (throwError))
import Control.Monad.Except (Except, ExceptT, runExceptT)
import Control.Monad.Reader qualified as R
import Control.Monad.State
import Data.Acid.TemplateHaskell (tyVarBndrName)
import Data.Array.ST
import Data.Data (DataRep (FloatRep))
import Data.List hiding (delete)
import Data.List qualified as L
import Data.List.Extra (groupOn)
import Data.Map (Map)
import Data.Map qualified as M
import Data.Maybe
import Data.Ord (Down (Down))
import Data.STRef
import Data.Time.Clock (UTCTime, getCurrentTime)
import GHC.Conc (STM (STM), TVar (TVar))
import GHC.Num.BigNat (raiseDivZero_BigNat)
import Hirc
import Hirc.Commands (userCommand)
import Hirc.Modules.Poker.Bank
import Hirc.Modules.Poker.Cards
import Hirc.Modules.Poker.Exception
import Hirc.Modules.Poker.Game hiding (endGame, incPosition)
import Hirc.Modules.Poker.Module
import Hirc.Modules.Poker.Player
import Hirc.Modules.Poker.STM
import System.Random
import System.Random.Shuffle (shuffle', shuffleM)
import System.Random.Stateful
import Text.Read (readMaybe)

--------------------------------------------------------------------------------
-- The main module

instance IsModule PokerModule where
  type ModuleState PokerModule = PokerState
  moduleName _ = "Poker"
  initModule _ = initPokerState
  shutdownModule _ = Nothing
  onStartup _ = Nothing
  onMessage _ = Just runPokerModule

pokerModule :: Module
pokerModule = newModule PokerModule

runPokerModule :: PokerM ()
runPokerModule = handle pokerExceptions $ do
  -- handle nick changes of players
  onCommand "NICK" $ doneAfter updatePlayerNicknames

  -- TODO: handle part/quit of players

  runBankCommands
  runPokerCommands
  where
    pokerExceptions :: SomeException -> PokerM ()
    pokerExceptions e = do
      msg <- getMessage
      -- ps <- runSTM askPokerState
      logM 1 $ "Exception on message: " ++ show e ++ "\n" ++ show msg -- ++ "\n" ++ show ps

runBankCommands :: PokerM ()
runBankCommands = do
  userCommand $ \case
    "bank help" -> doneAfter bankHelp
    text
      | text `elem` ["bank balance", "bb"] -> doneAfter bankBalance'
      | otherwise -> return ()

  -- check if game is running currently
  inGame <- runSTM userInGame

  userCommand $ \case
    "bank loan" -> doneAfter $ do
      if inGame
        then answer "You cannot loan money while in a game!"
        else bankLoan defaultLoan
    _ -> return ()

-- userCommand $ \"bank" "withdraw" amount -> doneAfter $
--   bankWithdraw $ Just (read amount)
-- userCommand $ \"bank" "withdraw"        -> doneAfter $ bankWithdraw Nothing

-- userCommand $ \"bank" "deposit" amount  -> doneAfter $
--   bankDeposit (Just $ read amount)
-- userCommand $ \"bank" "deposit"         -> doneAfter $ bankDeposit Nothing

defaultLoan :: Money
defaultLoan = 1000

minimumBalanceForLoan :: Money
minimumBalanceForLoan = 100

saveBank :: MonadIO m => Bank -> m ()
saveBank b = liftIO $ saveToJson b "bank.json"

runPokerCommands :: PokerM ()
runPokerCommands = do
  mg <- runSTM askMaybeGame

  when (maybe True isNewGame mg) $ do
    userCommand $ \case
      "poker help" -> doneAfter showHelp
      "players" -> doneAfter showPlayers
      text
        | text `elem` ["stack", "s"] -> doneAfter showStack
        | text `elem` ["poker join", "pj"] -> doneAfter joinPlayer'
        | text `elem` ["poker leave", "pl"] -> doneAfter $ do
            playerInGameGuard
            playerQuit
        | text `elem` ["deal", "deal cards", "d"] -> doneAfter $ do
            playerInGameGuard
            dealCards'
        | otherwise -> return ()

  -- while in game
  when (maybe False isActiveGame mg) $ do
    userCommand $ \case
      "pot" -> doneAfter showPot
      "cards" -> doneAfter showCards
      text
        | text `elem` ["stack", "s"] -> doneAfter showStack
        | text `elem` ["turn", "t"] -> doneAfter showCurrentPlayer
        | text `elem` ["order", "o"] -> doneAfter showCurrentOrder
        | text `elem` ["hand", "h"] -> doneAfter showHand
        | text `elem` ["check", "ch"] -> doneAfter $ do
            currentPlayerOnlyGuard
            check'
        | text `elem` ["call", "ca", "c"] -> doneAfter $ do
            currentPlayerOnlyGuard
            call'
        | [r, v] <- words text,
          r `elem` ["raise", "r"],
          Just amount <- readMaybe v -> doneAfter $ do
            currentPlayerOnlyGuard
            raise' amount
        | text `elem` ["fold", "f"] -> doneAfter $ do
            currentPlayerOnlyGuard
            fold'
        | otherwise -> return ()

-- userCommand $ \"all" "in"       -> doneAfter allIn

-- Help
showHelp :: PokerM ()
showHelp = do
  whisper "Playing Texas Hold'em, available commands are:"
  whisper "    poker help                --   show this help"
  whisper "    poker join                --   join a new game"
  whisper "    poker leave               --   leave the current game"
  whisper "    players                   --   show who is playing in the next game"
  whisper "    deal                      --   deal cards, start a new game"
  whisper "While playing:"
  whisper "    check/call/fold           --   check, call the current bet or fold your cards"
  whisper "    raise <num>               --   bet a new sum (at least big blind or the amount of the last raise)"
  -- whisper "    all in                    --   go all in"
  whisper "    pot                       --   show current pot"
  whisper "    stack                     --   show your current stack"
  whisper "    hand                      --   show your hand"
  whisper "    turn                      --   show whose turn it currently is"
  whisper "    order                     --   show current order"

--------------------------------------------------------------------------------
-- Helper

newtype PokerSTMExceptions = RunSTMFailed PokerState
  deriving (Exception, Show)

runSTM :: PokerSTM a -> PokerM a
runSTM rstm = do
  mchan <- getCurrentChannel
  withNickAndUser $ \n u -> do
    tvar <- R.ask
    liftIO $
      atomically $
        runReaderT `flip` (tvar, n, u, mchan) $
          (rstm `orElse`) $
            lift $ do
              ps <- readTVar tvar
              throwSTM $ RunSTMFailed ps

joinSTM :: PokerSTM (PokerM a) -> PokerM a
joinSTM = join . runSTM

--------------------------------------------------------------------------------
-- Exception handler

handlePokerExceptions :: PokerSTM (PokerM ()) -> PokerM ()
handlePokerExceptions stm = joinSTM $ handleP (return . hndl) stm
  where
    hndl :: PokerException -> PokerM ()
    hndl (InsufficientFunds need have) = do
      answer $
        "You don't have enough money! You need: "
          ++ show need
          ++ " (you have: "
          ++ show have
          ++ ")"
    hndl (CallFirst tc) = do
      answer $ "You have to call first: " ++ show tc
    hndl (RaiseTooSmall minimumRaise) = do
      answer $ "You have to raise at least " ++ show minimumRaise
    hndl NotEnoughPlayers = do
      answer "Waiting for more players! Type \"poker join\" to join the game."

--------------------------------------------------------------------------------
-- Information

showColors :: PokerM ()
showColors = do
  let c1 = head fullDeck
      c2 = fullDeck !! 13
      c3 = fullDeck !! 26
      c4 = fullDeck !! 39
  answer $ unwords (map colorCard [c1, c2, c3, c4])

showPlayers :: PokerM ()
showPlayers = do
  ps <- runSTM $ askPlayers `orElse` return []
  if null ps
    then say "No players yet."
    else say $ "Current players: " ++ intercalate ", " (map playerNickname ps)

showPot :: PokerM ()
showPot = joinSTM $ do
  g <- askGame
  p <- askPlayer
  t <- askToCall p
  return $
    answer $
      "You currently have "
        ++ show (playerPot p)
        ++ " in the pot"
        ++ (if t > 0 then " (" ++ show t ++ " to call)" else "")
        ++ ". (total pot size: "
        ++ show (totalPotSize g)
        ++ ")"

showStack :: PokerM ()
showStack = do
  p <- runSTM askPlayer
  answer $
    "You currently have "
      ++ show (playerStack p)
      ++ " in your stack"
      ++ (if playerPot p > 0 then " and " ++ show (playerPot p) ++ " in the current pot" else "")
      ++ "."

showStatus :: PokerM ()
showStatus = do
  s <- runSTM askGameState
  logM 2 $ "showStatus: " ++ show s
  case s of
    Left g -> do
      logM 2 "Next phase?!"
      logM 2 $ show $ isNextPhase g
      when (isNextPhase g) showCards
      showCurrentPlayer' g
    Right lm@LastManTakesItAll {} -> do
      lastMan lm
      runSTM resetGame
    Right sd@Showdown {} -> do
      showdown sd
      runSTM resetGame
  where
    lastMan (LastManTakesItAll p m) = do
      say $ playerNickname p ++ " wins the pot: " ++ show m
      b <- runSTM $ do
        updateBank $ deposit (playerUsername p) (playerStack p + m)
        askBank
      saveBank b

    showdown (Showdown ps m (wr, ws)) = do
      say "Game ended. Showdown!"

      -- show all cards with ranks
      let maxl = maximum $ map (length . playerNickname . fst) ps
      forM_ ps $ \(p, r) -> do
        let Just h = playerHand p
            pad = replicate (maxl - length (playerNickname p)) ' '
        say $
          "  "
            ++ playerNickname p
            ++ ": "
            ++ pad
            ++ unwords (map colorCard (hCards h))
            ++ " - "
            ++ show r

      -- return stack to all and pay out price to winning players
      let price = m `div` fromIntegral (length ws)
      b <- runSTM $ do
        forM_ ps $ \(p, _) -> do
          updateBank $ deposit (playerUsername p) (playerStack p)
        forM_ ws $ \p -> do
          updateBank $ deposit (playerUsername p) price
        askBank
      saveBank b

      -- show final game message
      case ws of
        [p] ->
          say $
            playerNickname p
              ++ " wins the pot of size "
              ++ show price
              ++ " ("
              ++ show wr
              ++ ")"
        _ ->
          say $
            "Split pot! The pot of size "
              ++ show m
              ++ " is split up between: "
              ++ intercalate ", " (map playerNickname ws)
              ++ " ("
              ++ show wr
              ++ ")"

showCommunityCards :: Game -> PokerM ()
showCommunityCards g = do
  case communityCards g of
    PreFlop -> return ()
    Flop (a, b, c) ->
      say $
        "Flop: " ++ unwords (map colorCard [a, b, c])
    Turn ((a, b, c), t) ->
      say $
        "Turn: " ++ unwords (map colorCard [a, b, c, t])
    River ((a, b, c), t, r) ->
      say $
        "River: " ++ unwords (map colorCard [a, b, c, t, r])

showCurrentPlayer :: PokerM ()
showCurrentPlayer = do
  g <- runSTM askGame
  showCurrentPlayer' g

showCurrentPlayer' :: Game -> PokerM ()
showCurrentPlayer' g = do
  logM 2 $ "Current player: " ++ show cp
  say $
    "Current player: "
      ++ playerNickname cp
      ++ (if tc > 0 then " (" ++ show tc ++ " to call)" else "")
  where
    cp = currentPlayer g
    tc = toCall g

showCurrentOrder :: PokerM ()
showCurrentOrder = do
  (order, fpos) <- runSTM $ (,) <$> askCurrentOrder <*> askFirstPosition

  let formatNames p =
        -- first player indication
        (if p == fpos then "*" else "")
          -- nick
          ++ playerNickname p
          -- (current pot/total wealth)
          ++ " ("
          ++ show (playerPot p)
          ++ "/"
          ++ show (playerStack p)
          ++ ")"

  say $ "Currently playing: " ++ intercalate ", " (map formatNames order)

showHand :: PokerM ()
showHand = do
  p <- runSTM askPlayer
  showHand' p

showHand' :: Player -> PokerM ()
showHand' p
  | Just (Hand hand) <- playerHand p =
      sendNoticeTo (playerNickname p) $ "Your hand: " ++ unwords (map colorCard hand)
  | otherwise =
      withNickAndUser $ \n u ->
        logM 1 $ "No hand found: " ++ show p ++ " (" ++ n ++ " / " ++ u ++ ")"

showCards :: PokerM ()
showCards = do
  g <- runSTM askGame
  case communityCards g of
    PreFlop -> answer "No cards have been played yet."
    Flop (a, b, c) ->
      say $
        "Flop: " ++ unwords (map colorCard [a, b, c])
    Turn ((a, b, c), t) ->
      say $
        "Turn: " ++ unwords (map colorCard [a, b, c, t])
    River ((a, b, c), t, r) ->
      say $
        "River: " ++ unwords (map colorCard [a, b, c, t, r])

--------------------------------------------------------------------------------
-- Bank commands
--

bankBalance' :: PokerM ()
bankBalance' = withUsername $ \u ->
  joinSTM $ do
    b <- askBank
    let bal = balance u b
        tot = totalLoans u b
    return $ answer $ "Your bank account balance is: " ++ show bal ++ " (you owe in total: " ++ show tot ++ ")"

bankLoan :: Money -> PokerM ()
bankLoan amount = withUsername $ \u -> do
  now <- liftIO getCurrentTime
  joinSTM $ do
    -- check if balance is small enough
    b <- askBank
    let bal = balance u b
    if bal <= minimumBalanceForLoan
      then do
        let l = Loan {loanUTC = now, loanAmount = amount - bal}
        updateBank $ newLoan u l
        b' <- askBank
        let t = totalLoans u b'
        return $ do
          saveBank b'
          answer $
            "You loaned " ++ show (loanAmount l) ++ " from the bank for a total of " ++ show t ++ " in loans."
      else
        return $
          answer $
            "You still have enough funds (more than " ++ show minimumBalanceForLoan ++ ")."

bankHelp :: PokerM ()
bankHelp = do
  whisper "The bank will loan you money to play poker with. The following commands are available:"
  whisper "    bank help                 --   show this help"
  whisper "    bank balance              --   show your current balance"
  whisper $ "    bank loan                 --   loan up to " ++ show defaultLoan ++ " from the bank once your balance is below " ++ show minimumBalanceForLoan

--------------------------------------------------------------------------------
-- Start game
--

joinPlayer' :: PokerM ()
joinPlayer' = joinSTM $ do
  ig <- userInGame
  if ig
    then return $ answer "You're already in the game!"
    else do
      n <- askNick
      u <- askUser
      -- check bank balance
      b <- askBank
      let bal = balance u b
      if bal < bigBlind
        then return $ do
          logM 2 $ show bal ++ " < " ++ show bigBlind
          answer $
            "You don't have enough money to join the game. You need at least "
              ++ show bigBlind
              ++ ". Type \"bank loan\" for more."
        else do
          -- withdraw all money from the bank and put it into the current game
          putBank $ withdraw u bal b
          -- add player to game
          updateGame $ joinPlayer $ newPlayer n u bal
          -- show info in channel
          return $ say $ "Player \"" ++ n ++ "\" joins the game."

playerQuit :: PokerM ()
playerQuit = handle playerNotFound . joinSTM $ do
  p <- askPlayer
  if isNothing (playerHand p)
    then do
      updateBank $ deposit (playerUsername p) (playerStack p)
      b <- askBank
      updateGame $ partPlayer p
      return $ do
        saveBank b
        say ("\"" ++ playerNickname p ++ "\" left the game.")
    else return $ answer "You have to fold first."
  where
    playerNotFound PlayerNotFound = done

updatePlayerNicknames :: PokerM ()
updatePlayerNicknames = withParams $ \[newNick] -> runSTM $ do
  u <- askUser
  let updateNick (Left g) =
        Left
          g
            { playerNicks = M.adjust (const newNick) u (playerNicks g)
            }
      updateNick o = o -- TODO: update game result nicks?

  -- change all players in all games
  updatePokerState $ \pokerState ->
    pokerState {games = M.map updateNick (games pokerState)}

--------------------------------------------------------------------------------
-- Play

dealCards' :: PokerM ()
dealCards' = handlePokerExceptions $ do
  -- update the main game
  updateGame dealCards

  -- get information about small and big blind
  g <- askGame
  let (n1 : n2 : _) = playersByNickName g
      (sb, bb) = blinds g

  -- pay blinds
  updateGame payBlinds

  return $ do
    say $
      "Starting a new round! The players are: "
        ++ intercalate ", " (M.elems (playerNicks g))
    say "Dealing hands…"
    notifyHands
    say $ n1 ++ " pays " ++ show sb ++ " (small blind)."
    say $ n2 ++ " pays " ++ show bb ++ " (big blind)."
    showCurrentPlayer

-- Send NOTICE to all players with their hands
notifyHands :: PokerM ()
notifyHands = do
  g <- runSTM askGame
  forM_ (players g) $ showHand' . fromJust . (`findPlayer` g)

playerInGameGuard :: PokerM ()
playerInGameGuard = do
  inGame <- runSTM userInGame
  unless inGame done

currentPlayerOnlyGuard :: PokerM ()
currentPlayerOnlyGuard = do
  isCur <- runSTM isCurrentPlayer
  unless isCur $ do
    answer "It's not your turn!"
    done

check' :: PokerM ()
check' = handlePokerExceptions $ do
  pl <- askCurrentPlayer
  updateGame check
  return $ do
    say $ playerNickname pl ++ " checks."
    showStatus

call' :: PokerM ()
call' = handlePokerExceptions $ do
  pl <- askCurrentPlayer
  tc <- askToCall pl
  if tc == 0
    then do
      updateGame check
      return $ do
        say $ playerNickname pl ++ " checks."
        showStatus
    else do
      updateGame call
      return $ do
        say $ playerNickname pl ++ " calls."
        showStatus

raise' :: Money -> PokerM ()
raise' m = handlePokerExceptions $ do
  pl <- askCurrentPlayer
  updateGame $ raise m
  return $ do
    say $ playerNickname pl ++ " raises the pot by " ++ show m
    showStatus

fold' :: PokerM ()
fold' = joinSTM $ do
  p <- askCurrentPlayer
  updateGame fold
  updateBank $ deposit (playerUsername p) (playerStack p)
  b <- askBank
  return $ do
    saveBank b
    say $ playerNickname p ++ " folds!"
    showStatus