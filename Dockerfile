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
