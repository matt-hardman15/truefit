# Truefit for iPhone

Scan an object with your iPhone's camera and LiDAR, clean it up, set exact dimensions (or rebuild it as an editable shape), and export a print-ready STL.

- **Scanning:** Apple's guided Object Capture, reconstructed on the phone. Needs an iPhone with LiDAR (12 Pro or a later Pro model) on iOS 17 or later.
- **Opening files:** USDZ, STL, OBJ and PLY from apps like Polycam or Scaniverse. A built-in sample scan works on any iPhone.
- **Editing:** tap any dimension drawn on the model, then type a value or drag its handle. Scans can scale or stretch at a cut plane (longer without fattening the head); rebuilt shapes change just that feature.
- **Bolts and pins:** rebuilds round, hex and threaded sections from a partial scan using the part's symmetry, suggests ISO metric threads, and snaps to standard bolt sizes.
- **Undo, redo and saved edits:** every change can be undone; edits are saved with each scan and restored when you reopen it.
- **Threads that print:** tight, standard or loose thread fit, a warning for threads too fine for FDM, and a matching hex nut for any threaded part.
- **Capture passes:** flip the object to scan the side that was on the table; Object Capture merges the laps.
- **Tools:** remove stray pieces, smoothing, flatten base, lay flat, exact W/D/H, caliper calibration, fit tolerance, mirror, shape detection and parametric rebuild (round or block, chamfer, round/D-shaft/hex hole), STL export (mm, Z up).
- **Billing:** StoreKit 2 subscription, "Truefit Pro" (monthly and yearly). Free users get scanning, cleanup, sizing, a preview of the rebuilt shape, and 3 exports. Pro unlocks rebuild, calibration and unlimited exports.

You don't need a Mac. GitHub's macOS machines build the app and upload it to TestFlight; you test on your phone and submit from the App Store Connect website.

---

## What's in here

| Path | What it is |
| --- | --- |
| `project.yml` | Project definition. The build generates `Truefit.xcodeproj` from it with XcodeGen. |
| `Truefit/App` | App entry, home screen, scan library |
| `Truefit/Capture` | Guided LiDAR capture and on-device reconstruction |
| `Truefit/Editor` | 3D viewport and the Clean / Size / Rebuild / Export steps |
| `Truefit/Mesh` | Mesh processing, shape detection, parametric solids, file import and STL export |
| `Truefit/Store` | Subscription state and paywall |
| `Truefit/Resources` | Icon, colors, privacy manifest |
| `.github/workflows/testflight.yml` | Cloud build: compile check on every push, TestFlight upload on demand |
| `docs/` | Privacy policy page and App Store listing copy |

---

## Setup, start to finish

### 1. Join the Apple Developer Program
Enroll at developer.apple.com/programs ($99/year). Approval usually takes a day or two. Your **Team ID** is under Membership details.

### 2. Register the app's bundle ID
developer.apple.com → Certificates, IDs & Profiles → Identifiers → **+** → App IDs → App.
Use an explicit ID you own, for example `com.matthardman.truefit`. No extra capabilities are needed (in-app purchase is on by default).

### 3. Create the app in App Store Connect
appstoreconnect.apple.com → Apps → **+** → New App. Platform iOS, pick the bundle ID from step 2. The name must be unique on the App Store; if "Truefit" is taken, try "Truefit: Scan to Print".

Then, under **Business** (formerly Agreements, Tax, and Banking), accept the **Paid Apps** agreement and fill in banking and tax. Subscriptions won't work, even in testing, until this is done.

### 4. Create the subscriptions
In your app → Monetization → Subscriptions:
1. Create a subscription group named **Truefit Pro**.
2. Add two subscriptions with these exact product IDs (they're in `Truefit/Store/Store.swift`):
   - `truefit.pro.monthly`, 1 month (suggested $3.99)
   - `truefit.pro.yearly`, 1 year (suggested $24.99, optionally with a 1-week free trial)
3. Give each a display name and description, and later a review screenshot of the paywall (take it from your TestFlight build).

### 5. Create an API key and add GitHub secrets
App Store Connect → Users and Access → Integrations → App Store Connect API → **Team Keys** → **+**. Role: **Admin** (needed so the cloud build can create signing certificates). Download the `.p8` file (you can only download it once) and note the **Key ID** and **Issuer ID**.

Create a **private** GitHub repository, push this folder to it, then go to Settings → Secrets and variables → Actions and add:

| Secret | Value |
| --- | --- |
| `DEVELOPMENT_TEAM` | Your Team ID (step 1) |
| `BUNDLE_ID` | The bundle ID from step 2 |
| `ASC_KEY_ID` | Key ID |
| `ASC_ISSUER_ID` | Issuer ID |
| `ASC_KEY_P8` | The full text of the `.p8` file, including the BEGIN and END lines |

### 6. Build and upload
GitHub → Actions → **TestFlight** → Run workflow. It compiles, signs and uploads in about 15–25 minutes. Every push to `main` also runs a quick compile check.

If a step fails, open the run, download the `build-log` artifact, and send it to Claude to fix.

GitHub's free plan includes 2,000 Actions minutes a month for private repos, and macOS minutes count 10×, so that's roughly 8–12 builds a month. A public repo has no limit.

### 7. Test on your iPhone
After the upload, App Store Connect processes the build (10–30 minutes). Then TestFlight → Internal Testing → add yourself. Install the **TestFlight** app on your iPhone and accept the invite.
Purchases in TestFlight use Apple's sandbox, so you're never charged. Check:
- Scan something small and matte on a plain table.
- Lay flat, smooth, set an exact width, calibrate.
- Rebuild (should show the paywall), subscribe in the sandbox, then rebuild and export.
- Export to Files and open the STL in Bambu Handy or Bambu Studio.

### 8. Host the privacy policy
Subscription apps need a privacy policy URL. In the GitHub repo: Settings → Pages → deploy from branch `main`, folder `/docs`. Your page will be at `https://YOUR-USERNAME.github.io/REPO-NAME/privacy.html`. Put that URL in `Truefit/Store/PaywallView.swift` (`Links.privacy`) and in App Store Connect.

### 9. Submit for review
In App Store Connect, on the 1.0 version:
- **Screenshots:** 6.9" iPhone (take them on your phone from the TestFlight build).
- **Description, keywords, subtitle:** copy from `docs/AppStoreListing.md`.
- **App Privacy:** "Data Not Collected". Scans stay on the device.
- **Age rating:** 4+.
- **In-App Purchases and Subscriptions:** attach both subscriptions to this version.
- **Review notes:** "Scanning requires a LiDAR iPhone. On other devices, tap one of the sample scans on the home screen to use every feature."
- Pick the build and submit. First reviews usually take 1–3 days.

---

## Notes

- This code hasn't been compiled yet. It was written without a Mac, so the first cloud build may turn up compile errors. Send the build log and they can be fixed quickly.
- Free exports are counted on the device. Reinstalling the app resets the count.
- Reconstruction runs fully on the phone at Apple's "reduced" detail. Small, matte objects with good light scan best.
