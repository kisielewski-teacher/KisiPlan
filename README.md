# Plan Mechanika

Aplikacja na Androida wyświetlająca plan lekcji z Librus Synergia dla uczniów i nauczycieli szkół. Pokazuje aktualną lekcję, odlicza czas do końca, wyświetla przerwy i dyżury nauczyciela, wysyła powiadomienia o ważnych momentach dnia.

---

## Spis treści

1. [Wymagania](#wymagania)
2. [Instalacja na Androidzie](#instalacja-na-androidzie) (w tym aktualizacje)
3. [Pierwsze uruchomienie i logowanie](#pierwsze-uruchomienie-i-logowanie)
4. [Instrukcja użytkowania](#instrukcja-użytkowania)
5. [Powiadomienia](#powiadomienia)
6. [Tryb offline](#tryb-offline)
7. [Rozwiązywanie problemów](#rozwiązywanie-problemów)
8. [Prywatność i zastrzeżenia](#prywatność-i-zastrzeżenia)
9. [Licencja](#licencja)
10. [Dla programisty](#dla-programisty)

---

## Wymagania

### Wymagania systemowe

| Platforma | Minimalna wersja                |
|-----------|---------------------------------|
| Android   | Android 7.0 (API 24) lub nowszy |

### Wymagania do działania

- **Konto Librus Synergia** – nauczycielskie lub uczniowskie
- **Połączenie z internetem** – przy pierwszym uruchomieniu i odświeżaniu planu
- **Zgoda na powiadomienia** – opcjonalna, do otrzymywania alertów

---

## Instalacja na Androidzie

### Metoda 1 – Pobranie APK z GitHuba (zalecana)

1. Na telefonie otwórz stronę wydań: [github.com/kisielewski-teacher/KisiPlan/releases/latest](https://github.com/kisielewski-teacher/KisiPlan/releases/latest) i pobierz plik **PlanMechanika.apk**.

2. **Zezwól na instalację z nieznanych źródeł:**
   - Ustawienia → Aplikacje → Specjalny dostęp do aplikacji → *Instalowanie nieznanych aplikacji*, wybierz przeglądarkę lub menedżer plików, z którego instalujesz, i włącz przełącznik.

3. **Otwórz pobrany plik APK**, naciśnij **Instaluj**, a po instalacji **Otwórz**.

### Aktualizacje

Aplikacja sama sprawdza (co kilka dni) wydania na GitHubie. Gdy jest nowa wersja, ikona aktualizacji na górze ekranu zmienia kolor z zielonego (aplikacja jest aktualna) na czerwony (jest nowa wersja) — naciśnij ją, aby pobrać i zainstalować nową wersję. Przy pierwszej aktualizacji Android poprosi o zgodę na instalowanie aplikacji z tego źródła. Możesz też ręcznie pobrać nowy plik APK z wydań (Metoda 1) — zainstaluje się na wierzch, a dane logowania zostaną zachowane.

### Metoda 2 – Instalacja przez kabel USB (dla zaawansowanych)

1. Podłącz telefon do komputera kablem USB.
2. Na telefonie włącz **Opcje programisty** i **Debugowanie USB** (Ustawienia → Informacje o telefonie → kliknij 7 razy numer kompilacji).
3. Pobierz plik APK z wydań i w terminalu na komputerze uruchom:

   ```powershell
   adb install -r PlanMechanika.apk
   ```

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

| Typ wpisu          | Wygląd                                        |
|--------------------|-----------------------------------------------|
| Lekcja             | karta z nazwą przedmiotu, salą i godziną      |
| Aktywna lekcja     | karta wyróżniona kolorem                      |
| Zastępstwo         | karta z oznaczeniem i oryginalnym przedmiotem |
| Dyżur (nauczyciel) | karta z miejscem dyżuru                       |
| Przerwa            | blok z zakresem godzin                        |

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

| Powiadomienie  | Opis                                     |
|----------------|------------------------------------------|
| Poranek        | Przypomnienie przed pierwszą lekcją      |
| Koniec przerwy | Alert, że przerwa zaraz się kończy       |
| Dyżur          | Informacja o miejscu dyżuru (nauczyciel) |
| Koniec zajęć   | Komunikat o zakończeniu lekcji na dziś   |

**Włączanie powiadomień:**

Na Androidzie: przy pierwszym uruchomieniu pojawi się prośba o zgodę — naciśnij *Zezwól*.

Przy pierwszym uruchomieniu pojawi się prośba o zgodę — naciśnij *Zezwól*. Jeśli odmówiłeś, włącz powiadomienia w ustawieniach systemu.

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

- Android: Ustawienia → Aplikacje → Plan Mechanika → Powiadomienia → włącz

### Godziny lekcji są błędne

- Godziny pobierane są z Librus Synergia
- Jeśli szkoła zmieniła godziny lekcji w systemie, odśwież plan
- Przy braku dostępu do API godzin aplikacja używa domyślnego planu szkoły

---

## Prywatność i zastrzeżenia

**Nieoficjalna aplikacja.** Plan Mechanika jest nieoficjalną, bezpłatną aplikacją, niezwiązaną z firmą Librus ani z żadną szkołą. „Librus” i „Synergia” są znakami należącymi do ich właścicieli. Aplikacja loguje się do Librus Synergia nieoficjalnie, więc zmiany po stronie Librusa mogą ją zepsuć. Używasz jej na własną odpowiedzialność.

**Prywatność.**

- Login i hasło są zapisane wyłącznie na Twoim telefonie, w bezpiecznym magazynie systemu (Android Keystore). Służą tylko do logowania do Librusa.
- Plan lekcji (tryb offline) jest zapisany lokalnie na telefonie. Autor aplikacji nie ma serwera i nie zbiera żadnych danych.
- Aplikacja łączy się tylko z serwerami Librusa oraz z GitHubem (sprawdzanie aktualizacji).
- Zgłoszenie błędu lub pomysłu (przycisk w aplikacji) wysyłasz sam. Możesz do niego dołączyć zrzut ekranu planu z dnia, a decyzja należy do Ciebie.
- Wylogowanie usuwa zapisane dane logowania z telefonu.

---

## Licencja

Kod źródłowy jest udostępniony na licencji [MIT](LICENSE). Logo szkoły (`flutter_app/assets/Mechanik.png`) jest użyte za zgodą dyrekcji i nie jest objęte tą licencją.

---

## Dla programisty

Sekcja dla osoby rozwijającej projekt.

### Wymagania do developmentu

- Flutter SDK 3.x
- Android Studio lub VS Code z wtyczką Flutter

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

### Ograniczenia techniczne

- Aplikacja zależy od API Librus Synergia — zmiany po stronie Librusa mogą wymagać aktualizacji
- Dane offline nie zastępują aktualnego planu, pełnią rolę awaryjną
