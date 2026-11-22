#!/usr/bin/env python3
"""Derive phone-only metadata and catalogs from the common files; never maintain a stale copy."""
import importlib.util
import json
import plistlib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CATALOGS = ("Localizable.xcstrings", "InfoPlist.xcstrings")
# The store build has no ring (Plan MZ decision 5), so its usage strings keep the wording from before
# the ring, in every language the catalog carries.
PHONE_USAGE_STRINGS = {
    "NSHealthUpdateUsageDescription": {
        "en": "Avenkin saves workout data from fitness coaching sessions to Apple Health.",
        "ar": "يحفظ Avenkin بيانات التمارين من جلسات التدريب البدني في Apple Health.",
        "es-MX": "Avenkin guarda en Apple Health los datos de entrenamiento de las sesiones con el entrenador de fitness.",
        "fr-CA": "Avenkin enregistre dans Apple Health les données d'entraînement de vos séances de coaching en mise en forme.",
        "hu": "Az Avenkin a fitneszedzői foglalkozások edzésadatait az Apple Healthbe menti.",
        "it": "Avenkin salva in Apple Health i dati degli allenamenti delle sessioni di coaching fitness.",
        "ja": "Avenkinは、フィットネスコーチングセッションのワークアウトデータをApple Healthに保存します。",
        "ko": "Avenkin은 피트니스 코칭 세션의 운동 데이터를 Apple Health에 저장합니다.",
        "nl": "Avenkin bewaart trainingsgegevens van fitnesscoachingsessies in Apple Health.",
        "pt-BR": "O Avenkin salva no Apple Health os dados de treino das sessões com o preparador físico.",
        "ru": "Avenkin сохраняет в Apple Health данные о тренировках, проведенных с фитнес-тренером.",
        "ur": "Avenkin فٹنس کوچنگ سیشنز کا ورزش کا ڈیٹا Apple Health میں محفوظ کرتا ہے۔",
        "zh-Hans": "Avenkin 会将健身指导课程中的锻炼数据存储到 Apple Health。",
        "zh-Hant": "Avenkin 會將健身指導課程的鍛鍊資料儲存到 Apple Health。",
    },
}


def artifact_check():
    """The artifact check owns the banned-text rule, so the filter and the check cannot disagree."""
    spec = importlib.util.spec_from_file_location("check_phone_only", ROOT / "Scripts/check-phone-only-artifact.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def phone_info(info):
    info = dict(info)
    for key in ("MWDAT", "UISupportedExternalAccessoryProtocols",
                "NSBluetoothAlwaysUsageDescription", "NSBluetoothPeripheralUsageDescription"):
        info.pop(key, None)
    info["UIBackgroundModes"] = [value for value in info.get("UIBackgroundModes", [])
                                 if value not in ("external-accessory", "bluetooth-central", "bluetooth-peripheral")]
    info["LSApplicationQueriesSchemes"] = [value for value in info.get("LSApplicationQueriesSchemes", [])
                                          if value != "fb-viewapp"]
    url_types = []
    for entry in info.get("CFBundleURLTypes", []):
        entry = dict(entry)
        entry["CFBundleURLSchemes"] = [value for value in entry.get("CFBundleURLSchemes", [])
                                       if not value.startswith("mwdat-")]
        if entry["CFBundleURLSchemes"]:
            url_types.append(entry)
    info["CFBundleURLTypes"] = url_types
    for key, wording in PHONE_USAGE_STRINGS.items():
        if key in info:
            info[key] = wording["en"]
    info["AvenkinBuildVariant"] = "phone-only"
    # The store product never carries Meta's experimental glasses APIs (Plan JV): stamped as such
    # literally, not left to a build setting.
    info["AvenkinDATExperimental"] = "NO"
    return info


def phone_catalog(catalog, check=None):
    """Drops every entry that carries banned text in its key or in any translation."""
    check = check or artifact_check()
    kept = {key: entry for key, entry in catalog["strings"].items()
            if not check.catalog_entry_terms(key, entry.get("localizations", {}))}
    for key, wording in PHONE_USAGE_STRINGS.items():
        if key in kept:
            kept[key] = phone_usage_entry(kept[key], wording)
    return dict(catalog, strings=kept)


def phone_usage_entry(entry, wording):
    """The entry with the store build's wording in every language it has; the rest unchanged."""
    localizations = {}
    for language, value in entry.get("localizations", {}).items():
        unit = value.get("stringUnit")
        if unit is not None and language in wording:
            value = dict(value, stringUnit=dict(unit, value=wording[language]))
        localizations[language] = value
    return dict(entry, localizations=localizations)


if __name__ == "__main__":
    source = plistlib.loads((ROOT / "OpenGlasses/Info.plist").read_bytes())
    destination = ROOT / ".generated/Info.phone-only.plist"
    destination.parent.mkdir(exist_ok=True)
    destination.write_bytes(plistlib.dumps(phone_info(source), sort_keys=False))
    print("Derived phone-only Info.plist from the common metadata.")
    check = artifact_check()
    for name in CATALOGS:
        catalog = json.loads((ROOT / "OpenGlasses/Sources/Resources" / name).read_text(encoding="utf-8"))
        phone = phone_catalog(catalog, check)
        (destination.parent / name).write_text(json.dumps(phone, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"Derived phone-only {name}: dropped {len(catalog['strings']) - len(phone['strings'])} entries.")
