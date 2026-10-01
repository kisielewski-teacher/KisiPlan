# TODO – przegląd projektu (start: 2026-10-01)

Zasady: dopisuję, gdy znajdę coś do zrobienia lub do zdecydowania; ogarnięte punkty po prostu usuwam.
Stan na start: `flutter analyze` – 0 problemów, `flutter test` – 63/63 OK.

## 🟡 Do zrobienia (bezpieczne, mogę zrobić po Twoim „ok”)

### Kod

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

## 🔐 Wymiana klucza podpisu bez reinstalacji

Decyzja: identyfikator aplikacji `com.example.kisiplan` **zostaje** (aplikacji nie ma w Sklepie Play, zmiana wymagałaby reinstalacji
i ręcznego przenoszenia loginu/hasła). Problem to tylko klucz podpisu `shared-debug.keystore.jks` (hasło „android” w repo).
Android 9+ pozwala go wymienić bez reinstalacji dzięki rotacji klucza (`apksigner rotate` → łańcuch podpisów, plik lineage).

- [ ] Wygenerować nowy keystore release (lokalnie, kopia zapasowa poza repo!) i plik lineage: stary klucz → nowy (`apksigner rotate`).
- [ ] Wydanie podpisać nowym kluczem z lineage (v3), zachowując zgodność ze starym podpisem dla Androida 7–8 (sprawdzić, czy te telefony przyjmą aktualizację;
      jeśli nie – zdecydować, czy ktoś z nimi w ogóle jest).
- [ ] Keystore i hasła w GitHub Secrets; zmiana `signingConfigs` i joba `release` w `.github/workflows/build.yml`.
- [ ] **Test na jednym telefonie**: zainstalować obecną wersję (stary podpis) → zaktualizować przez aplikację do wersji z nowym kluczem → login i dane zostają.
- [ ] Dopiero po udanym teście: usunąć `shared-debug.keystore.jks` z repo i wyjątek z `flutter_app/.gitignore` (budowanie debug lokalnie przejdzie na zwykły debug.keystore).
- [ ] Opcjonalnie, kosmetyka bez reinstalacji: nazwa repozytorium `KisiPlan` → `PlanMechanika` (GitHub przekierowuje; poprawić `update_service.dart`, instrukcję HTML i `docs/*`).
