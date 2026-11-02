# TODO – przegląd projektu (start: 2026-10-01)

Zasady: dopisuję, gdy znajdę coś do zrobienia lub do zdecydowania; ogarnięte punkty po prostu usuwam.
Stan na start: `flutter analyze` – 0 problemów, `flutter test` – 63/63 OK.

## 🟡 Do zrobienia (bezpieczne, mogę zrobić po Twoim „ok”)

### Kod

- [ ] `timetable_service.dart` (~3000 linii) – ogromny plik z łańcuchem logowania (SSO/portal/bearer/gateway). **Tylko ostrożnie**:
      łańcucha logowania NIE ruszamy bez żywego testu przed i po na prawdziwych kontach (nauczyciel + uczeń) – ukryte zależności przez wspólny
      stan (cookie `oauth_token` z kroku `portalSzkoly` jest potrzebny uczniowskiej ścieżce REST/gateway; wcześniejsze „przycięcie” dało 401).
      Bezpieczne kroki, w kolejności: (1) mechaniczny podział pliku (parsowanie HTML/dyżurów, ciasteczka) na mniejsze pliki bez zmiany logiki, pod osłoną testów;
      (2) dopiero potem, z kontem testowym ucznia i logami z telefonu/Windows, ustalić które gałęzie SSO naprawdę się wykonują.
- [ ] `update_service.dart`: pobiera APK bez weryfikacji (tylko HTTPS z GitHuba; podpis sprawdza Android). Dodać
      sprawdzenie sumy SHA-256 z notatek wydania? (opcjonalnie, zależne od decyzji o kluczu)
- [ ] Brak testów samego logowania do Librusa (`TimetableService.login`, łańcuch SSO) – wymaga makiety odpowiedzi serwera; testy na żywo robimy ręcznie.

### Logowanie do Librusa po zmianie z listopada 2026

- [ ] Naprawione dla nauczyciela (start logowania od `synergia.librus.pl/loguj/portalSzkoly`, żeby był `state`/`oauth_state` i cookie `oauth_token`). **Uczeń**: start logowania zostawiony po staremu
      (działa przez REST/gateway) – sprawdzić na koncie ucznia, czy po zmianie Librusa nadal działa; jeśli nie, zastosować ten sam start (`/loguj/portalRodzina`?).
- [ ] Wyłączyć lub ograniczyć diagnostykę w żółtym komunikacie „Sesja wygasła” (v1.4.43–45), gdy sytuacja się uspokoi – zostawić krótką wersję.
- [ ] Ryzyko ogólne: aplikacja korzysta z nieoficjalnych mechanizmów Librusa, więc każda zmiana zabezpieczeń je psuje – rozważyć kontakt z Librusem w sprawie oficjalnego dostępu.
- [ ] Skrypt do śledzenia logowania w przeglądarce (Playwright + Edge, bez zapisu haseł) dobrze działa do porównań z aplikacją – dodać do `testy/` na przyszłe awarie.

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
