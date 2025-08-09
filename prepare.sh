#!/bin/bash
# Tento skript vygeneruje všechny potřebné soubory pro sestavení,
# nahrání a nasazení Python trading bota do Kubernetes jako trvalý Deployment.

set -e # Ukončí skript při první chybě
echo "🚀 Generuji strukturu projektu pro K8S nasazení (Deployment)..."

# Vytvoření adresářové struktury
mkdir -p src k8s
echo "Vytvořeny adresáře: src/, k8s/"

# --- Generování Python zdrojových kódů ---

# Soubor: src/main.py
cat <<'EOF' > src/main.py
import json
import time
import datetime
import math
import threading
from decimal import Decimal, getcontext, ROUND_DOWN
from loguru import logger
import os

# Importy z lokálních modulů
import config
from bybit_client import BybitClient
from analysis_provider import AnalysisProvider

# Vytvoření adresáře pro logy, pokud neexistuje
os.makedirs("/app/logs", exist_ok=True)

# Nastavení logování pro výstup do konzole (vhodné pro K8S)
logger.add(lambda msg: print(msg, end=""), format="{message}", level="INFO")
# Logování do souboru, který bude díky mapování viditelný na hostitelském stroji
logger.add("/app/logs/trading_bot.log", rotation="10 MB", level="DEBUG")

class TradingBot:
    """
    Hlavní třída orchestrující obchodního bota.
    """
    def __init__(self, bybit_client: BybitClient, analysis_provider: AnalysisProvider):
        self.bybit = bybit_client
        self.analyzer = analysis_provider
        getcontext().prec = 10  # Nastavení přesnosti pro Decimal

    def run(self):
        """
        Spustí hlavní cyklus obchodního bota v nekonečné smyčce,
        přičemž každý ticker zpracovává v samostatném vlákně.
        """
        logger.info("🚀 Spouštím obchodního bota v režimu nasazení (Deployment)...")
        while True:
            logger.info("--- Zahajuji nový cyklus paralelního zpracování ---")
            threads = []
            try:
                for ticker in config.TICKERS:
                    # Vytvoření a spuštění vlákna pro každý ticker
                    thread = threading.Thread(target=self._process_ticker, args=(ticker.strip(),))
                    threads.append(thread)
                    thread.start()
                    logger.info(f"Spuštěno vlákno pro ticker: {ticker.strip()}")

                # Počkat na dokončení všech vláken
                for thread in threads:
                    thread.join()

            except Exception as e:
                logger.critical(f"Došlo k neočekávané chybě v hlavním cyklu: {e}", exc_info=True)

            logger.info(f"🏁 Všechna vlákna dokončila cyklus. Čekám {config.SLEEP_INTERVAL_SECONDS} sekund před dalším spuštěním.")
            time.sleep(config.SLEEP_INTERVAL_SECONDS)

    def _wait_for_confirmation(self, trade: dict, ticker: str) -> dict | None:
        """
        Počká na uzavření další svíčky a ověří, zda potvrzuje směr obchodu.
        Vrací data potvrzovací svíčky, pokud byl signál potvrzen, jinak None.
        """
        trade_type = trade.get("tradeType", "").lower()
        if not trade_type:
            return None

        try:
            interval_minutes = int(config.INTERVAL)
        except ValueError:
            logger.error(f"[{ticker}] Neplatný formát intervalu: {config.INTERVAL}. Očekává se celé číslo.")
            return None

        # Výpočet času do uzavření další svíčky
        now = datetime.datetime.utcnow()
        next_candle_minute = (math.floor(now.minute / interval_minutes) + 1) * interval_minutes
        
        if next_candle_minute >= 60:
            next_candle_time = now.replace(minute=0, second=0, microsecond=0) + datetime.timedelta(hours=1)
        else:
            next_candle_time = now.replace(minute=next_candle_minute, second=0, microsecond=0)
            
        sleep_seconds = (next_candle_time - now).total_seconds() + 5 # +5 sekund pro jistotu
        
        if sleep_seconds > 0:
            logger.info(f"[{ticker}] Obdržen signál pro {trade_type}. Čekám {sleep_seconds:.2f} sekund na uzavření potvrzovací svíce...")
            time.sleep(sleep_seconds)

        # Stažení nejnovější svíčky pro potvrzení
        logger.info(f"[{ticker}] Stahuji nejnovější svíci pro potvrzení...")
        latest_candles_df = self.bybit.get_ohlcv_data(ticker, config.INTERVAL, limit=1)
        if latest_candles_df.empty:
            logger.error(f"[{ticker}] Nepodařilo se stáhnout potvrzovací svíci.")
            return None
            
        confirmation_candle = latest_candles_df.iloc[-1]
        candle_open = confirmation_candle["open"]
        candle_close = confirmation_candle["close"]
        
        logger.info(f"[{ticker}] Potvrzovací svíce: Open={candle_open}, Close={candle_close}")

        # Kontrola potvrzení
        if trade_type == "long":
            if candle_close > candle_open:
                logger.success(f"[{ticker}] Potvrzeno: Býčí svíce (Close > Open).")
                return confirmation_candle.to_dict()
            else:
                logger.warning(f"[{ticker}] Nepotvrzeno: Svíce nebyla býčí.")
                return None
                
        elif trade_type == "short":
            if candle_close < candle_open:
                logger.success(f"[{ticker}] Potvrzeno: Medvědí svíce (Close < Open).")
                return confirmation_candle.to_dict()
            else:
                logger.warning(f"[{ticker}] Nepotvrzeno: Svíce nebyla medvědí.")
                return None
                
        return None

    def _process_ticker(self, ticker: str):
        """
        Provede kompletní obchodní logiku pro jeden ticker.
        """
        logger.info(f"--- Začínám zpracování pro ticker: {ticker} ---")
        try:
            # KONTROLA POZICE
            open_position_size = self.bybit.get_open_position_size(ticker)
            if open_position_size > 0:
                logger.info(f"[{ticker}] Pozice o velikosti {open_position_size} je již otevřena. Přeskakuji.")
                return

            # 1. Získání dat pro analýzu
            df = self.bybit.get_ohlcv_data(ticker, config.INTERVAL, limit=100)
            if df.empty:
                return

            # 2. Získání obchodního návrhu od AI
            trade_suggestion = self.analyzer.get_trade_suggestion(df, ticker, config.INTERVAL, config.LEVERAGE)
            if not trade_suggestion:
                return
            
            logger.success(f"[{ticker}] Analýza od AI úspěšně přijata.")
            logger.info(f"[{ticker}] Odpověď od AI: {json.dumps(trade_suggestion, indent=2)}")

            # 3. Čekání na potvrzovací svíci
            confirmation_candle_data = self._wait_for_confirmation(trade_suggestion, ticker)
            if not confirmation_candle_data:
                logger.warning(f"[{ticker}] Vstupní signál nebyl potvrzen další svící. Obchod se neuskuteční.")
                return

            # 4. Validace s nejnovější cenou
            current_price = confirmation_candle_data["close"]
            if not self._is_trade_valid(trade_suggestion, current_price, ticker):
                logger.warning(f"[{ticker}] Návrh od AI nesplnil validační kritéria po potvrzení. Obchod se neuskuteční.")
                return

            # 5. Příprava a odeslání příkazu
            order_details = self._prepare_order(trade_suggestion, ticker)
            if not order_details:
                return

            self.bybit.place_order(order_details)

        except Exception as e:
            logger.error(f"[{ticker}] V hlavní smyčce nastala kritická chyba: {e}", exc_info=True)
        finally:
            logger.info(f"--- Dokončeno zpracování pro ticker: {ticker} ---")


    def _is_trade_valid(self, trade: dict, current_price: float, ticker: str) -> bool:
        try:
            entry_max = Decimal(str(trade["entryZone"]["max"]))
            entry_min = Decimal(str(trade["entryZone"]["min"]))
            stop_loss = Decimal(str(trade["stopLoss"]))
            trade_type = trade["tradeType"].lower()

            if trade_type == "long" and stop_loss >= entry_min:
                logger.error(f"[{ticker}] Validační chyba: U LONG obchodu musí být Stop-Loss níže než vstupní zóna.")
                return False
            
            if trade_type == "short" and stop_loss <= entry_max:
                logger.error(f"[{ticker}] Validační chyba: U SHORT obchodu musí být Stop-Loss výše než vstupní zóna.")
                return False

            price_diff = abs(Decimal(str(current_price)) - entry_min) / Decimal(str(current_price))
            if price_diff > Decimal("0.05"):
                logger.warning(f"[{ticker}] Validační varování: Vstupní zóna je >5% od aktuální ceny ({current_price}).")

            return True
        except (KeyError, ValueError) as e:
            logger.error(f"[{ticker}] Chyba ve struktuře nebo hodnotách JSON od AI: {e}")
            return False


    def _prepare_order(self, trade: dict, ticker: str) -> dict | None:
        try:
            entry_min = Decimal(str(trade["entryZone"]["min"]))
            entry_max = Decimal(str(trade["entryZone"]["max"]))
            entry_price = (entry_min + entry_max) / Decimal("2")
            stop_loss_price = Decimal(str(trade["stopLoss"]))
            take_profit_price = Decimal(str(trade["targetPrice"]))

            risk_per_trade_usd = Decimal(str(config.RISK_PER_TRADE_USD))
            price_diff = abs(entry_price - stop_loss_price)
            if price_diff == 0:
                logger.error(f"[{ticker}] Vstupní cena a Stop Loss jsou identické. Velikost pozice nelze vypočítat.")
                return None
            
            position_size = risk_per_trade_usd / price_diff
            qty_step = self.bybit.get_qty_step(ticker)
            position_size = position_size.quantize(qty_step, rounding=ROUND_DOWN)

            logger.info(f"[{ticker}] Vypočtená velikost pozice: {position_size} {ticker.replace('PERP', '')}")
            
            if position_size <= 0:
                logger.warning(f"[{ticker}] Vypočtená velikost pozice je 0. Obchod nebude proveden.")
                return None

            return {
                "symbol": ticker,
                "side": "Buy" if trade["tradeType"].lower() == "long" else "Sell",
                "orderType": "Limit",
                "qty": str(position_size),
                "price": str(entry_price),
                "takeProfit": str(take_profit_price),
                "stopLoss": str(stop_loss_price),
            }
        except (KeyError, ValueError) as e:
            logger.error(f"[{ticker}] Chyba při přípravě příkazu z dat od AI: {e}")
            return None

if __name__ == "__main__":
    try:
        bybit_client = BybitClient(
            api_key=config.BYBIT_API_KEY,
            api_secret=config.BYBIT_SECRET_KEY,
            is_demo=config.IS_DEMO
        )
        analysis_provider = AnalysisProvider(
            api_key=config.TOGETHER_API_KEY,
            model_name=config.AI_MODEL_NAME
        )
        
        bot = TradingBot(bybit_client=bybit_client, analysis_provider=analysis_provider)
        bot.run()
    except ValueError as e:
        logger.critical(f"Chyba při inicializaci: {e}")
    except Exception as e:
        logger.critical(f"Neočekávaná chyba při spuštění: {e}", exc_info=True)
EOF

# Soubor: src/config.py
cat <<'EOF' > src/config.py
import os

# Načítání konfigurace z proměnných prostředí (poskytnutých K8S)
# API Klíče
BYBIT_API_KEY = os.getenv('BYBIT_API_KEY')
BYBIT_SECRET_KEY = os.getenv('BYBIT_SECRET_KEY')
TOGETHER_API_KEY = os.getenv('TOGETHER_API_KEY')

# Provozní nastavení
IS_DEMO = os.getenv('IS_DEMO', 'True').lower() in ('true', '1', 't')
AI_MODEL_NAME = os.getenv('AI_MODEL_NAME', "openai/gpt-oss-120b")
# Interval spánku v sekundách mezi cykly v režimu Deployment
SLEEP_INTERVAL_SECONDS = int(os.getenv('SLEEP_INTERVAL_SECONDS', 300))

# Obchodní parametry
# Načte string s tickery oddělenými čárkou a převede ho na list
TICKERS = [ticker.strip() for ticker in os.getenv('TICKERS', "ETHPERP,BTCPERP").split(',')]
INTERVAL = os.getenv('INTERVAL', "5")
LEVERAGE = int(os.getenv('LEVERAGE', 50))
RISK_PER_TRADE_USD = int(os.getenv('RISK_PER_TRADE_USD', 20))

# Validace, zda jsou klíče nastaveny
if not all([BYBIT_API_KEY, BYBIT_SECRET_KEY, TOGETHER_API_KEY]):
    raise ValueError("Jedna nebo více povinných proměnných prostředí (API klíčů) není nastaveno. Zkontrolujte K8S Secret.")
EOF

# Soubor: src/bybit_client.py
cat <<'EOF' > src/bybit_client.py
import pandas as pd
from loguru import logger
from pybit.unified_trading import HTTP
from decimal import Decimal
import json

class BybitClient:
    def __init__(self, api_key: str, api_secret: str, is_demo: bool = True):
        try:
            self.session = HTTP(
                demo=is_demo,
                testnet=False,
                api_key=api_key,
                api_secret=api_secret,
            )
            logger.success("Úspěšně připojeno k Bybit API.")
        except Exception as e:
            logger.error(f"Nepodařilo se připojit k Bybit API: {e}")
            raise

    def get_open_position_size(self, symbol: str) -> float:
        """
        Získá velikost otevřené pozice pro daný symbol.
        Vrací velikost pozice jako float, nebo 0.0, pokud pozice neexistuje nebo nastane chyba.
        """
        try:
            positions = self.session.get_positions(
                category="linear",
                symbol=symbol,
            )
            if positions and positions.get("retCode") == 0 and positions["result"]["list"]:
                # API vrací list, bereme první (a jediný) záznam pro daný symbol
                position_size = float(positions["result"]["list"][0].get("size", 0.0))
                return position_size
            return 0.0
        except Exception as e:
            logger.error(f"[{symbol}] Nepodařilo se získat otevřené pozice: {e}")
            # V případě chyby je bezpečnější předpokládat, že pozice není otevřená.
            return 0.0

    def get_ohlcv_data(self, symbol: str, interval: str, limit: int = 100) -> pd.DataFrame:
        logger.info(f"[{symbol}] Stahuji tržní data...")
        try:
            kline = self.session.get_kline(
                category="linear", symbol=symbol, interval=interval, limit=limit
            )
            if not (kline and kline.get('retCode') == 0):
                logger.error(f"[{symbol}] Chyba při stahování K-line dat: {kline}")
                return pd.DataFrame()

            df = pd.DataFrame(
                kline["result"]["list"],
                columns=["timestamp", "open", "high", "low", "close", "volume", "turnover"]
            ).astype(float)
            df["timestamp"] = pd.to_datetime(df["timestamp"], unit="ms")
            df.sort_values(by="timestamp", inplace=True, ascending=True)
            logger.success(f"[{symbol}] Staženo a zpracováno {len(df)} svíček.")
            return df
        except Exception as e:
            logger.error(f"[{symbol}] Selhání při zpracování dat z Bybitu: {e}")
            return pd.DataFrame()

    def get_qty_step(self, symbol: str) -> Decimal:
        try:
            instr_info = self.session.get_instruments_info(category="linear", symbol=symbol)
            qty_step = instr_info["result"]["list"][0]["lotSizeFilter"]["qtyStep"]
            return Decimal(str(qty_step))
        except Exception as e:
            logger.error(f"[{symbol}] Nepodařilo se získat qty_step: {e}. Používám defaultní hodnotu '0.001'.")
            return Decimal("0.001")

    def place_order(self, order_details: dict):
        symbol = order_details['symbol']
        logger.info(f"[{symbol}] Odesílám {order_details['side']} příkaz pro {order_details['qty']} {symbol}...")
        try:
            order = self.session.place_order(
                category="linear", **order_details, timeInForce="GTC"
            )
            if order and order.get("retCode") == 0:
                logger.success(f"[{symbol}] Obchodní příkaz byl úspěšně odeslán!")
                logger.info(json.dumps(order, indent=2))
            else:
                logger.error(f"[{symbol}] Odeslání příkazu selhalo: {order}")
        except Exception as e:
            logger.error(f"[{symbol}] Výjimka při odesílání příkazu: {e}", exc_info=True)
EOF

# Soubor: src/analysis_provider.py
cat <<'EOF' > src/analysis_provider.py
import pandas as pd
import pandas_ta as ta
from loguru import logger
from together import Together
import json

class AnalysisProvider:
    def __init__(self, api_key: str, model_name: str):
        self.client = Together(api_key=api_key)
        self.model_name = model_name
        logger.info(f"AnalysisProvider inicializován s modelem: {self.model_name}")

    def _prepare_data_with_indicators(self, df: pd.DataFrame) -> pd.DataFrame:
        df.ta.ema(length=21, append=True)
        df.ta.ema(length=50, append=True)
        df.ta.rsi(length=14, append=True)
        df.dropna(inplace=True)
        return df.round(4)

    def _build_prompt(self, ticker: str, interval: str, leverage: int, df_with_indicators: pd.DataFrame) -> str:
        csv_data = df_with_indicators.to_csv(index=False)
        return f"""
        Jsi "Data-Driven Swing Trader", kvantitativní finanční analytik. Tvým úkolem je analyzovat data a POUZE INTERPRETOVAT PŘEDEM VYPOČTENÉ indikátory. Navrhni jeden obchod s nejvyšší pravděpodobností úspěchu pro ticker {ticker}. Tvůj výstup musí být výhradně JSON objekt.

        # VSTUPNÍ DATA
        * **Ticker:** {ticker}
        * **Časový rámec:** {interval} minut
        * **Data OHLCV včetně indikátorů (EMA_21, EMA_50, RSI_14):**
          ```csv
          {csv_data}
          ```
        # KLÍČOVÝ KONTEXT A PRAVIDLA
        1. **Řízení rizika:** Maximální ztráta na obchod je přesně 20 USD při páce {leverage}.
        2. **Vstupní strategie:** Hledej vstupy co nejblíže aktuální ceně (poslední 'close' v datech).

        # PRACOVNÍ POSTUP
        1. Analyzuj poskytnutá data včetně sloupců EMA_21, EMA_50 a RSI_14.
        2. Identifikuj nejlepší swingový obchod (Long nebo Short).
        3. Vytvoř zdůvodnění v sekci "rationale".
        4. Výsledek naformátuj VÝHRADNĚ jako JSON objekt podle definované struktury.

        # FORMÁT VÝSTUPU (POVINNÝ JSON)
        ```json
        {{
          "ticker": "{ticker}",
          "tradeType": "string (Long/Short)",
          "entryZone": {{ "min": "number", "max": "number" }},
          "stopLoss": "number",
          "targetPrice": "number",
          "rationale": {{
            "marketStructure": "string",
            "keyLevels": "string",
            "indicators": "string",
            "riskRewardRatio": "string"
          }}
        }}
        ```
        """

    def get_trade_suggestion(self, df: pd.DataFrame, ticker: str, interval: str, leverage: int) -> dict | None:
        df_processed = self._prepare_data_with_indicators(df.copy())
        if df_processed.empty:
            logger.warning(f"[{ticker}] Po výpočtu indikátorů nezůstala žádná data k analýze.")
            return None
            
        prompt = self._build_prompt(ticker, interval, leverage, df_processed)
        logger.info(f"[{ticker}] Odesílám požadavek na TogetherAI s modelem {self.model_name}...")
        
        try:
            response = self.client.chat.completions.create(
                model=self.model_name,
                messages=[{"role": "user", "content": prompt}],
                response_format={"type": "json_object"},
            )
            analysis_text = response.choices[0].message.content
            return json.loads(analysis_text)
        except Exception as e:
            logger.error(f"[{ticker}] Chyba při komunikaci s AI: {e}")
            return None
EOF
echo "Vytvořeny Python zdrojové soubory v src/"

# --- Generování souborů pro build a deployment ---

# Soubor: requirements.txt
cat <<'EOF' > requirements.txt
pybit
loguru
pandas
together
pandas-ta
numpy==1.23.5
EOF
echo "Vytvořen soubor requirements.txt"

# Soubor: Dockerfile
cat <<'EOF' > Dockerfile
# Použijeme štíhlý a oficiální Python image
FROM python:3.10-slim

# Nastavíme pracovní adresář uvnitř kontejneru
WORKDIR /app

# Zkopírujeme soubor se závislostmi
COPY requirements.txt .

# Nainstalujeme závislosti
# --no-cache-dir snižuje velikost image
RUN pip install --no-cache-dir -r requirements.txt

# Zkopírujeme zdrojové kódy aplikace
COPY src/ .

# Nastavíme oprávnění pro zápis pro všechny uživatele
RUN chmod -R 777 /app

# Příkaz, který se spustí při startu kontejneru
CMD ["python", "main.py"]
EOF
echo "Vytvořen soubor Dockerfile"

# Soubor: Makefile
cat <<'EOF' > Makefile
# Makefile pro automatizaci build, push a deploy procesů
# Proměnné
IMAGE_NAME = trading-bot
IMAGE_TAG = latest
REGISTRY = localhost:5000
FULL_IMAGE_NAME = $(REGISTRY)/$(IMAGE_NAME):$(IMAGE_TAG)

# Cíle
.PHONY: all build push deploy clean logs

all: build push deploy

build:
	@echo "--- Sestavuji Docker image: $(FULL_IMAGE_NAME) ---"
	@docker build -t $(FULL_IMAGE_NAME) .

push:
	@echo "--- Nahrávám image do lokálního registru: $(FULL_IMAGE_NAME) ---"
	@docker push $(FULL_IMAGE_NAME)

deploy:
	@echo "--- Nasazuji/aktualizuji aplikaci v Kubernetes ---"
	@kubectl apply -f k8s/
	@echo "--- Provádím rollout restart deploymentu pro okamžité projevení změn ---"
	@kubectl rollout restart deployment/trading-bot-deployment

clean:
	@echo "--- Uklízím Kubernetes zdroje ---"
	@sudo kubectl delete -f k8s/ --ignore-not-found=true

logs:
	@echo "--- Zobrazuji logy podu (pro ukončení stiskněte Ctrl+C) ---"
	@kubectl logs -f -l app=trading-bot

EOF
echo "Vytvořen soubor Makefile"

# --- Generování Kubernetes Manifestů ---

# Soubor: k8s/configmap.yaml
cat <<'EOF' > k8s/configmap.yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: trading-bot-config
  namespace: default
data:
  # Tyto hodnoty můžete snadno měnit přes Lens nebo `kubectl edit configmap`
  # Zadejte seznam tickerů oddělených čárkou
  TICKERS: "ETHPERP,BTCPERP,SOLPERP"
  IS_DEMO: "True"
  INTERVAL: "5"
  LEVERAGE: "50"
  RISK_PER_TRADE_USD: "20"
  AI_MODEL_NAME: "openai/gpt-oss-120b"
  # Interval v sekundách mezi jednotlivými běhy bota v režimu Deployment
  SLEEP_INTERVAL_SECONDS: "300"
EOF
echo "Vytvořen K8S ConfigMap v k8s/configmap.yaml"

# Soubor: k8s/secrets.yaml
cat <<'EOF' > k8s/secrets.yaml
apiVersion: v1
kind: Secret
metadata:
  name: trading-bot-secrets
  namespace: default
type: Opaque
data:
  # DŮLEŽITÉ: Vložte sem své skutečné API klíče zakódované v Base64.
  # Tento zástupný text je platný Base64, aby `kubectl apply` neselhal.
  # Použijte příkaz: echo -n 'VAS_SKUTECNY_KLIC' | base64
  BYBIT_API_KEY: "ejhHejRqTG5Cdmk1T09URGho"
  BYBIT_SECRET_KEY: "dFNmYmZKYnlMVFpibk5GMmRQQkwzblpLU0J6azZuaHVpS2F2"
  TOGETHER_API_KEY: "YjNhN2U1OTU5YTRmYjYzYTYzNDY5ZDUzMTRkZjVlMzI5MTlhODhlZmRiNWE0ZjdjZjFkMzc3MzUzYWViZDM0MA=="
EOF
echo "Vytvořen K8S Secret v k8s/secrets.yaml - NEZAPOMEŇTE DOPLNIT KLÍČE!"

# Soubor: k8s/deployment.yaml
cat <<'EOF' > k8s/deployment.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trading-bot-deployment
  namespace: default
  labels:
    app: trading-bot
spec:
  replicas: 1
  selector:
    matchLabels:
      app: trading-bot
  template:
    metadata:
      labels:
        app: trading-bot
    spec:
      volumes:
        - name: trading-bot-logs
          hostPath:
            # Cesta na hostitelském uzlu.
            # Adresář bude vytvořen, pokud neexistuje.
            path: /mnt/tradingbot/logs
            type: DirectoryOrCreate
      containers:
      - name: trading-bot-container
        # Použije image z lokálního registru
        image: localhost:5000/trading-bot:latest
        imagePullPolicy: Always # Vždy stáhne nejnovější verzi image
        volumeMounts:
          - name: trading-bot-logs
            mountPath: /app/logs
        envFrom:
          # Načtení všech hodnot z ConfigMap jako proměnné prostředí
          - configMapRef:
              name: trading-bot-config
          # Načtení všech hodnot ze Secret jako proměnné prostředí
          - secretRef:
              name: trading-bot-secrets
        # --- Health Probes ---
        # Liveness probe kontroluje, zda kontejner stále běží a není zamrzlý.
        livenessProbe:
          exec:
            command:
            - test
            - -f
            - /app/main.py
          initialDelaySeconds: 30
          periodSeconds: 60
        # Readiness probe kontroluje, zda je aplikace připravena přijímat provoz (zde spíše symbolické).
        readinessProbe:
          exec:
            command:
            - test
            - -f
            - /app/main.py
          initialDelaySeconds: 15
          periodSeconds: 30
      restartPolicy: Always
EOF
echo "Vytvořen K8S Deployment v k8s/deployment.yaml"

echo ""
echo "✅ Hotovo! Struktura projektu byla úspěšně vygenerována."
echo ""
echo "DALŠÍ KROKY:"
echo "1. Doplňte své Base64-enkódované API klíče do souboru 'k8s/secrets.yaml'."
echo "   (Použijte příkaz: echo -n 'VAS_SKUTECNY_KLIC' | base64)"
echo "2. Upravte konfiguraci v 'k8s/configmap.yaml' (seznam tickerů, interval spánku atd.)."
echo "3. Ujistěte se, že máte spuštěný lokální Docker registry: 'docker run -d -p 5000:5000 --restart=always --name registry registry:2'"
echo "4. Spusťte 'make all' pro sestavení, nahrání a nasazení aplikace."
echo "5. Pro sledování logů použijte 'make logs'. Logy najdete také na hostitelském stroji v /mnt/tradingbot/logs."
