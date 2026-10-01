# Plan Mechanika – Flutter Mobile App

Aplikacja mobilna na Androida wyświetlająca plan lekcji z Librus Synergia dla uczniów i nauczycieli.

Pełna instrukcja obsługi, wymagania i instrukcja instalacji znajdują się w [głównym README](../README.md).

## Funkcje

- logowanie kontem Librus Synergia (nauczyciel lub uczeń)
- aktualna lekcja z odliczaniem czasu do końca
- przerwy między lekcjami z licznikiem
- plan na dziś i plan tygodniowy
- dyżury nauczyciela pobierane z osobnego źródła Librusa
- zastępstwa wyróżnione osobnym kolorem
- powiadomienia o początku dnia, końcu przerwy, początku dyżuru i końcu zajęć
- tryb offline – ostatnio pobrany plan zapisywany lokalnie
- widżet ekranu głównego, odblokowanie biometryczne, synchronizacja w tle
- automatyczne sprawdzanie aktualizacji (GitHub Releases)
- stopka z autorem aplikacji

## Struktura projektu

- `lib/models/` – model lekcji i logika czasu
- `lib/screens/` – ekran logowania i ekran główny
- `lib/services/` – logowanie i pobieranie planu z Librusa, powiadomienia, zapis lokalny (baza, bezpieczny magazyn), synchronizacja w tle, widget, biometria, aktualizacje z GitHuba
- `test/` – testy jednostkowe (`flutter test`)

## Bezpieczeństwo

- Dane logowania są przechowywane w `flutter_secure_storage` (szyfrowane)
- Hasło nie jest wysyłane na własny serwer – tylko bezpośrednio na API Librusa

## Szybki start dla programisty

```powershell
cd flutter_app
flutter pub get
flutter run
```

## Budowanie APK

```powershell
flutter build apk --debug     # wersja testowa
flutter build apk --release   # wersja produkcyjna
```

Gotowy plik: `build\app\outputs\flutter-apk\app-debug.apk`

## Autor

Marcin Kisielewski
