# Szkołplan – Flutter Mobile App

Aplikacja mobilna na Androida i iOS wyświetlająca plan lekcji z Librus Synergia dla uczniów i nauczycieli.

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
- stopka z autorem aplikacji

## Struktura projektu

```text
lib/
├── main.dart                          # Punkt wejścia aplikacji
├── models/
│   └── lesson.dart                    # Model lekcji + logika czasu
├── services/
│   ├── timetable_service.dart         # Logowanie i pobieranie planu z Librusa
│   ├── notification_service.dart      # Logika powiadomień
│   └── secure_storage_service.dart    # Bezpieczny zapis danych logowania
└── screens/
    ├── login_screen.dart              # Ekran logowania
    └── home_screen.dart               # Ekran główny
```

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
