# TODO – przegląd projektu (start: 2026-10-01)

Zasady: dopisuję, gdy znajdę coś do zrobienia lub do zdecydowania; ogarnięte punkty po prostu usuwam.
Stan na start: `flutter analyze` – 0 problemów, `flutter test` – 63/63 OK.

## 🟡 Do zrobienia (bezpieczne, mogę zrobić po Twoim „ok”)

### Porządek w repo

- [ ] Usunąć `.venv/` (stare środowisko Pythona, skrypt `fetch_plan.py` już nie istnieje) i pusty `.sixth/`.

### Dokumentacja

- [ ] `docs/plan-mechanika-instrukcja.html` (171 KB, zrzuty base64) – ładuje czcionki z Google Fonts (RODO – IP odwiedzających do Google). Rozważyć hostowanie czcionek lokalnie.

### Kod

- [ ] `web/index.html`, `web/manifest.json`: „A new Flutter project.”, nazwa `szkolplan` → poprawić lub usunąć web.
- [ ] `build.gradle.kts`: komentarze `TODO: Specify your own unique Application ID` (powiązane z decyzją wyżej).
- [ ] `timetable_service.dart` (3004 linie) – ogromny plik; wiele zagnieżdżonych prób logowania (SSO/portal/bearer/gateway),
      **uwaga**: wg pamięci projektu łańcuch SSO „wygląda na martwy, ale nie jest” (zależność od `oauth_token`) –
      NIE przycinać bez testu na żywo. Najpierw ustalić testami, co jest naprawdę nieużywane, dopiero potem czyścić.
- [ ] ~190 wywołań `debugPrint`, część loguje fragmenty odpowiedzi serwera (do 1000 znaków body, 40 znaków tokenów).
      W release `debugPrint` nadal trafia do logcat → ograniczyć do `kDebugMode` / usunąć logowanie tokenów i body.
- [ ] `update_service.dart`: pobiera APK bez weryfikacji (tylko HTTPS z GitHuba; podpis sprawdza Android). Dodać
      sprawdzenie sumy SHA-256 z notatek wydania? (opcjonalnie, zależne od decyzji o kluczu)
- [ ] `update_service.dart`: `http.Client()` w `download` nie jest zamykany (drobny wyciek).
- [ ] Brak testów dla `update_service`, `login`, `secure_storage` (testowane są głównie model/powiadomienia/widget).
- [ ] `android:allowBackup` nie ustawione w manifeście → domyślnie true; sprawdzić czy kopie zapasowe nie obejmują sekretów
      (flutter_secure_storage ma własne reguły, ale warto jawnie ustawić `allowBackup="false"`).
- [ ] `SCHEDULE_EXACT_ALARM` / `REQUEST_INSTALL_PACKAGES` – uprawnienia „wrażliwe”; potwierdzić, że oba są naprawdę potrzebne
      (install – tak, dla auto-aktualizacji; exact alarm – do sprawdzenia).

### Zależności i licencje

- [ ] Zależności z nowymi wersjami głównymi (wymagają zmiany ograniczeń w `pubspec.yaml` i testu na telefonie): `flutter_local_notifications` 21→22,
      `flutter_secure_storage` 10→11 (**ryzyko**: sprawdzić, że zapisane hasło nadal się odczytuje po aktualizacji aplikacji), `home_widget` 0.9→0.10, `local_auth` 2→3.
      Aktualizować pojedynczo, każdą z testem na telefonie (logowanie, powiadomienia, widżet, biometria).
- [ ] Ostrzeżenie Fluttera: Kotlin Gradle Plugin → „Built-in Kotlin” (`android.builtInKotlin=false`); pluginy flutter_timezone, home_widget, workmanager, shared_preferences – czekać na ich aktualizacje.
- [ ] Czcionki/ikony: `assets/icona.png` – potwierdzić autorstwo/prawa do ikony.

## ⏳ Czeka na wspólną reinstalację u wszystkich użytkowników

Zrobić **razem, w jednym wydaniu**, gdy zdecydujesz, że można poprosić wszystkich o odinstalowanie starej aplikacji
(zmiana identyfikatora lub podpisu = Android traktuje to jako inną aplikację → utrata danych i brak auto-aktualizacji).
Do tego czasu NIE ruszać.

- [ ] **Identyfikator aplikacji** `com.example.kisiplan` → własny, np. `pl.slupsk.mechanik.planmechanika`
      (`build.gradle.kts`: `namespace` i `applicationId`; katalog i `package` w `MainActivity.kt` i `TimetableWidgetProvider.kt`;
      kanał `com.example.kisiplan/installer` w `MainActivity.kt` i `update_service.dart`; komentarz TODO w `build.gradle.kts`).
- [ ] **Prawdziwy klucz podpisu wydań** zamiast `shared-debug.keystore.jks` (hasło „android” w repo): nowy keystore w GitHub Secrets,
      zmiana `signingConfigs` i joba `release` w `.github/workflows/build.yml`; usunąć debugowy keystore z repo i wyjątek z `flutter_app/.gitignore`.
- [ ] **Nazwa bazy** `szkolplan.db` → `plan_mechanika.db` (`local_db_service.dart`) – przy reinstalacji i tak zaczyna się od zera, więc bez migracji.
- [ ] **Nazwa repozytorium** `KisiPlan` → `PlanMechanika` (GitHub robi przekierowania, ale poprawić `update_service.dart`, instrukcję HTML i `docs/*`).
- [ ] Po wydaniu: zapowiedź dla użytkowników (zrzut/instrukcja „odinstaluj starą, zainstaluj nową”) i sprawdzenie na telefonie, że aktualizator nie oferuje starego pakietu.
