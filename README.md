# Szkołplan

Aplikacja mobilna wyświetlająca plan lekcji z Librus Synergia dla uczniów i nauczycieli szkół. Pokazuje aktualną lekcję, odlicza czas do końca, wyświetla przerwy i dyżury nauczyciela, wysyła powiadomienia o ważnych momentach dnia.

---

## Spis treści

1. [Wymagania](#wymagania)
2. [Instalacja na Androidzie](#instalacja-na-androidzie)
3. [Instalacja na iPhonie](#instalacja-na-iphone)
4. [Pierwsze uruchomienie i logowanie](#pierwsze-uruchomienie-i-logowanie)
5. [Instrukcja użytkowania](#instrukcja-użytkowania)
6. [Powiadomienia](#powiadomienia)
7. [Tryb offline](#tryb-offline)
8. [Rozwiązywanie problemów](#rozwiązywanie-problemów)
9. [Dla programisty](#dla-programisty)

---

## Wymagania

### Wymagania systemowe

| Platforma | Minimalna wersja |
|-----------|-----------------|
| Android   | Android 6.0 (API 23) lub nowszy |
| iOS       | iOS 12.0 lub nowszy |

### Wymagania do działania

- **Konto Librus Synergia** – nauczycielskie lub uczniowskie
- **Połączenie z internetem** – przy pierwszym uruchomieniu i odświeżaniu planu
- **Zgoda na powiadomienia** – opcjonalna, do otrzymywania alertów

---

## Instalacja na Androidzie

### Metoda 1 – Instalacja z pliku APK (zalecana)

1. **Pobierz plik APK** na telefon (np. przez e-mail, pendrive lub bezpośrednio).

2. **Zezwól na instalację z nieznanych źródeł:**
   - Na Androidzie 8.0 i nowszym: otwórz *Ustawienia → Aplikacje → Specjalny dostęp do aplikacji → Instalowanie nieznanych aplikacji*, wybierz aplikację (np. Menedżer plików lub przeglądarkę), włącz przełącznik.
   - Na Androidzie 7.x i starszym: otwórz *Ustawienia → Zabezpieczenia*, włącz opcję **Nieznane źródła**.

3. **Otwórz pobrany plik APK** za pomocą menedżera plików.

4. Naciśnij **Instaluj** i poczekaj na zakończenie.

5. Po instalacji naciśnij **Otwórz**.

> **Uwaga:** Przy każdej aktualizacji aplikacji wystarczy zainstalować nowy plik APK — poprzednie dane (dane logowania) zostaną zachowane.

### Metoda 2 – Instalacja przez kabel USB (dla zaawansowanych)

1. Podłącz telefon do komputera kablem USB.
2. Na telefonie włącz **Opcje programisty** i **Debugowanie USB** (Ustawienia → Informacje o telefonie → kliknij 7 razy numer kompilacji).
3. W terminalu na komputerze uruchom:

   ```powershell
   flutter install
   ```

   lub

   ```powershell
   adb install build\app\outputs\flutter-apk\app-debug.apk
   ```

---

## Instalacja na iPhonie

Instalacja na iOS wymaga jednej z poniższych metod, ponieważ Apple nie pozwala instalować aplikacji spoza App Store bez podpisania kodu.

### Metoda 1 – TestFlight (najłatwiejsza, wymaga zaproszenia)

1. Zainstaluj aplikację **TestFlight** z App Store.
2. Otwórz link z zaproszeniem od dewelopera.
3. Zainstaluj aplikację przez TestFlight.

### Metoda 2 – AltStore (bez konta dewelopera)

1. Na komputerze (Windows lub Mac) zainstaluj **AltServer** ze strony [altstore.io](https://altstore.io).
2. Podłącz iPhone kablem USB do komputera.
3. W AltServer kliknij *Install AltStore* i wybierz swój iPhone.
4. Na telefonie w *Ustawienia → Ogólne → Zarządzanie urządzeniem* zaufaj certyfikatowi dewelopera.
5. Otwórz AltStore na telefonie, przejdź do zakładki **My Apps**, naciśnij **+** i wybierz plik `.ipa` aplikacji.

> **Uwaga:** AltStore wymaga co 7 dni odświeżenia certyfikatu (lub 1 rok przy płatnym koncie Apple Developer).

### Metoda 3 – Xcode (wymaga komputera Mac i konta Apple)

1. Na Macu zainstaluj Xcode z App Store.
2. Otwórz projekt w folderze `flutter_app/ios/` w Xcode.
3. Podłącz iPhone kablem, wybierz go jako urządzenie docelowe.
4. W ustawieniach projektu skonfiguruj swoje Apple ID jako *Team*.
5. Kliknij **Run** (▶) — Xcode zbuduje i zainstaluje aplikację.
6. Na iPhonie w *Ustawienia → Ogólne → Zarządzanie urządzeniem* zaufaj certyfikatowi.

---

## Pierwsze uruchomienie i logowanie

Po pierwszym otwarciu aplikacji pojawi się ekran logowania.

### Logowanie jako nauczyciel

1. Wybierz rolę **Nauczyciel**.
2. W polu *Login* wpisz identyfikator nauczyciela z Librus Synergia.
3. W polu *Hasło* wpisz hasło.
4. Naciśnij **Zaloguj**.

### Logowanie jako uczeń

1. Wybierz rolę **Uczeń**.
2. W polu *Login* wpisz login ucznia z Librus Synergia.
3. W polu *Hasło* wpisz hasło.
4. Naciśnij **Zaloguj**.

> Dane logowania są zapisywane bezpiecznie w pamięci telefonu. Przy kolejnym uruchomieniu aplikacja zaloguje się automatycznie.

---

## Instrukcja użytkowania

### Ekran główny

Po zalogowaniu wyświetla się ekran główny z następującymi elementami:

**Na górze:**
- aktualna godzina i data
- informacja o tym, co teraz trwa

**Stan aktualny może wyglądać tak:**
- `Teraz masz: Matematyka – sala 201` — trwa lekcja, z odliczaniem czasu do końca
- `Przerwa – jeszcze 3 min` — trwa przerwa, z informacją o następnej lekcji
- `Zajęcia zakończone` — na dziś nie ma już lekcji

**Pasek postępu** pod informacją o stanie pokazuje, ile czasu upłynęło z bieżącej lekcji lub przerwy.

---

### Plan na dziś

Poniżej sekcji aktualnego stanu wyświetla się lista wszystkich wpisów na dziś:

| Typ wpisu | Wygląd |
|-----------|--------|
| Lekcja | karta z nazwą przedmiotu, salą i godziną |
| Aktywna lekcja | karta wyróżniona kolorem |
| Zastępstwo | karta z oznaczeniem i oryginalnym przedmiotem |
| Dyżur (nauczyciel) | karta z miejscem dyżuru |
| Przerwa | blok z zakresem godzin |

---

### Plan tygodniowy

Pod planem na dziś znajduje się plan całego tygodnia. Każdy dzień można rozwinąć i zwinąć, naciskając na jego nagłówek. W środku widoczne są wszystkie lekcje i przerwy danego dnia.

---

### Odświeżanie planu

W prawym górnym rogu ekranu znajduje się przycisk **odświeżania** (ikona kółka). Naciśnięcie pobiera nowy plan z Librusa. Zaleca się odświeżanie rano przed lekcjami, aby uwzględnić ewentualne zastępstwa.

---

### Wylogowanie

Obok przycisku odświeżania znajduje się przycisk **wylogowania**. Po wylogowaniu usunięta zostaje zapisana sesja — przy kolejnym uruchomieniu aplikacja poprosi o dane logowania.

---

## Powiadomienia

Aplikacja może wysyłać powiadomienia o ważnych momentach dnia:

| Powiadomienie | Opis |
|---------------|------|
| Poranek | Przypomnienie przed pierwszą lekcją |
| Koniec przerwy | Alert, że przerwa zaraz się kończy |
| Dyżur | Informacja o miejscu dyżuru (nauczyciel) |
| Koniec zajęć | Komunikat o zakończeniu lekcji na dziś |

**Włączanie powiadomień:**

Na Androidzie: przy pierwszym uruchomieniu pojawi się prośba o zgodę — naciśnij *Zezwól*.

Na iPhonie: przy pierwszym uruchomieniu pojawi się prośba o zgodę — naciśnij *Zezwól*. Jeśli odmówiłeś, wejdź w *Ustawienia → Szkołplan → Powiadomienia* i włącz je ręcznie.

---

## Tryb offline

Aplikacja automatycznie zapisuje ostatnio pobrany plan lokalnie na telefonie.

Jeśli przy uruchomieniu nie uda się połączyć z Librusem (brak internetu, przerwa techniczna), aplikacja wyświetli **ostatnio zapisany plan** z informacją, że dane mogą być nieaktualne.

Oznacza to, że:
- aplikacja działa nawet bez internetu
- zapisany plan może nie uwzględniać ostatnich zmian (zastępstw, odwołanych lekcji)
- po przywróceniu połączenia warto nacisnąć przycisk odświeżania

---

## Rozwiązywanie problemów

### Aplikacja pokazuje błąd logowania

- Sprawdź login i hasło — te same, co do strony [synergia.librus.pl](https://synergia.librus.pl)
- Upewnij się, że wybrałeś właściwą rolę (Nauczyciel / Uczeń)
- Sprawdź połączenie z internetem

### Plan jest nieaktualny lub pusty

- Naciśnij przycisk odświeżania w prawym górnym rogu
- Jeśli problem nie znika, wyloguj się i zaloguj ponownie

### Aplikacja nie wysyła powiadomień

- Android: Ustawienia → Aplikacje → Szkołplan → Powiadomienia → włącz
- iPhone: Ustawienia → Szkołplan → Powiadomienia → włącz

### Godziny lekcji są błędne

- Godziny pobierane są z Librus Synergia
- Jeśli szkoła zmieniła godziny lekcji w systemie, odśwież plan
- Przy braku dostępu do API godzin aplikacja używa domyślnego planu szkoły

### Na iPhonie aplikacja przestała działać po 7 dniach

- Dotyczy instalacji przez AltStore z bezpłatnym kontem Apple
- Otwórz AltStore na telefonie (połączonym z komputerem z AltServerem) i odśwież certyfikat

---

## Dla programisty

Sekcja dla osoby rozwijającej projekt.

### Wymagania do developmentu

- Flutter SDK 3.x
- Android Studio lub VS Code z wtyczką Flutter
- Dla iOS: komputer Mac z Xcode 14+

### Szybki start

```powershell
cd C:\Programy\Szkolplan\flutter_app
flutter pub get
flutter run
```

### Budowanie APK (Android)

```powershell
flutter build apk --debug     # wersja debug (do testów)
flutter build apk --release   # wersja release (do dystrybucji)
```

Gotowy plik APK znajduje się w:
`build\app\outputs\flutter-apk\app-debug.apk`
lub
`build\app\outputs\flutter-apk\app-release.apk`

### Budowanie IPA (iOS) – wymaga Maca

```bash
flutter build ipa
```

### Budowanie na Windows

```powershell
flutter build windows
```

### Struktura projektu

```text
flutter_app/lib/
├── main.dart                          # Start aplikacji
├── models/
│   └── lesson.dart                    # Model lekcji
├── screens/
│   ├── login_screen.dart              # Ekran logowania
│   └── home_screen.dart               # Ekran główny
└── services/
    ├── timetable_service.dart         # Pobieranie planu z Librusa
    ├── notification_service.dart      # Logika powiadomień
    └── secure_storage_service.dart    # Zapis danych logowania
```

### Skrypt testowy Python

Skrypt `fetch_plan.py` służy do testowania pobierania danych z Librusa poza aplikacją.

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
pip install -r requirements.txt
python fetch_plan.py
```

### Ograniczenia techniczne

- Aplikacja zależy od API Librus Synergia — zmiany po stronie Librusa mogą wymagać aktualizacji
- Wersja webowa nie obsługuje pełnego logowania z powodu ograniczeń CORS
- Dane offline nie zastępują aktualnego planu, pełnią rolę awaryjną
