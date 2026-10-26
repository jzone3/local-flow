#!/usr/bin/env python3
"""Public TestFlight link for the build this run uploaded: fills in the beta test info, waits for Apple to
finish processing, adds the build to the external "Public" group (public link on) and submits it for
Beta App Review. Safe to rerun. Env: as asc-signing.py, plus ASC_CONTACT_PHONE and GITHUB_RUN_NUMBER."""
import importlib.util, os, sys, time

spec = importlib.util.spec_from_file_location("asc", os.path.join(os.path.dirname(__file__), "asc-signing.py"))
asc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(asc)
call = asc.call

EMAIL = "jared.zoneraich@cognition.ai"
DESCRIPTION = ("You speak faster than you type. Local Flow keeps all voice dictation private: transcription runs "
               "on your iPhone and nothing is sent anywhere. Add the Local Flow keyboard, tap Dictate, talk, "
               "then come back and tap Insert.")
WHAT_TO_TEST = ("Open Local Flow once to download the speech model (574 MB, use Wi-Fi). Then Settings → General → "
                "Keyboard → Keyboards → Add New Keyboard → Local Flow, and turn on Allow Full Access. In any text "
                "field switch to the Local Flow keyboard, tap Dictate, talk (tap to stop, or hold and let go), tap ◀ "
                "in the top-left to go back, then tap Insert.")
REVIEW_NOTES = ("No account needed. The app records only while the on-screen button is on and transcribes on device "
                "with an open-source Whisper model downloaded on first launch. The keyboard asks for Full Access only "
                "to read the last transcript from the shared App Group.")


def upsert(list_path, kind, attrs, create_rel, create_attrs, match):
    _, res = call("GET", list_path)
    data = res.get("data") or []
    data = [d for d in (data if isinstance(data, list) else [data]) if match(d)]
    if data:
        call("PATCH", f"/{kind}/{data[0]['id']}", {"data": {"type": kind, "id": data[0]["id"], "attributes": attrs}})
        return data[0]["id"]
    _, res = call("POST", f"/{kind}", {"data": {"type": kind, "attributes": {**attrs, **create_attrs}, "relationships": create_rel}})
    return res["data"]["id"]


def main():
    phone = os.environ.get("ASC_CONTACT_PHONE", "").strip()
    if not phone:
        print("ASC_CONTACT_PHONE not set; skipping the public link.")
        return
    _, apps = call("GET", "/apps?filter[bundleId]=com.jzone3.LocalFlow.iOS")
    app = apps["data"][0]["id"]
    app_rel = {"app": {"data": {"type": "apps", "id": app}}}

    upsert(f"/apps/{app}/betaAppLocalizations", "betaAppLocalizations",
           {"description": DESCRIPTION, "feedbackEmail": EMAIL, "marketingUrl": "https://www.uselocalflow.app",
            "privacyPolicyUrl": "https://github.com/jzone3/local-flow#privacy"},
           app_rel, {"locale": "en-US"}, match=lambda d: d["attributes"]["locale"] == "en-US")
    _, detail = call("GET", f"/apps/{app}/betaAppReviewDetail")
    call("PATCH", f"/betaAppReviewDetails/{detail['data']['id']}", {"data": {
        "type": "betaAppReviewDetails", "id": detail["data"]["id"], "attributes": {
            "contactFirstName": "Jared", "contactLastName": "Zoneraich", "contactPhone": phone,
            "contactEmail": EMAIL, "demoAccountRequired": False, "notes": REVIEW_NOTES}}})
    print("Beta test info filled in")

    run = os.environ["GITHUB_RUN_NUMBER"]
    for _ in range(90):
        _, builds = call("GET", f"/builds?filter[app]={app}&filter[version]={run}")
        state = builds["data"][0]["attributes"]["processingState"] if builds["data"] else "NOT YET LISTED"
        if state == "VALID":
            break
        if state in ("FAILED", "INVALID"):
            sys.exit(f"Apple rejected build {run} while processing ({state})")
        print(f"Build {run}: {state}")
        time.sleep(30)
    else:
        sys.exit(f"Build {run} still processing after 45 minutes; rerun later")
    build = builds["data"][0]["id"]

    _, locs = call("GET", f"/builds/{build}/betaBuildLocalizations")
    en = [d for d in locs["data"] if d["attributes"]["locale"] == "en-US"]
    if en:
        call("PATCH", f"/betaBuildLocalizations/{en[0]['id']}", {"data": {"type": "betaBuildLocalizations",
             "id": en[0]["id"], "attributes": {"whatsNew": WHAT_TO_TEST}}})
    else:
        call("POST", "/betaBuildLocalizations", {"data": {"type": "betaBuildLocalizations",
             "attributes": {"locale": "en-US", "whatsNew": WHAT_TO_TEST},
             "relationships": {"build": {"data": {"type": "builds", "id": build}}}}})

    _, groups = call("GET", f"/apps/{app}/betaGroups")
    public = [g for g in groups["data"] if g["attributes"]["name"] == "Public"]
    if public:
        group = public[0]["id"]
    else:
        _, res = call("POST", "/betaGroups", {"data": {"type": "betaGroups", "attributes": {
            "name": "Public", "publicLinkEnabled": True, "publicLinkLimitEnabled": False, "feedbackEnabled": True},
            "relationships": app_rel}})
        group = res["data"]["id"]
    call("POST", f"/betaGroups/{group}/relationships/builds", {"data": [{"type": "builds", "id": build}]})
    status, _ = call("POST", "/betaAppReviewSubmissions", {"data": {"type": "betaAppReviewSubmissions",
                     "relationships": {"build": {"data": {"type": "builds", "id": build}}}}}, ok=(201, 409, 422))
    print("Submitted for Beta App Review" if status == 201 else f"Review submission returned {status} (already submitted?)")
    _, g = call("GET", f"/betaGroups/{group}")
    print("PUBLIC LINK:", g["data"]["attributes"].get("publicLink"))


if __name__ == "__main__":
    main()
