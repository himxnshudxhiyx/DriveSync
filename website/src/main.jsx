import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './style.css'

const UPDATED = "November 23, 2026 (two-way sync)"

function Nav() {
  return (
    <header className="nav">
      <a href="/" className="brand"><img src="/icon.png" alt="" />DriveSync</a>
      <nav>
        <a href="/privacy">Privacy</a>
        <a href="/terms">Terms</a>
      </nav>
    </header>
  )
}

function Footer() {
  return (
    <footer>
      <span>© 2026 DriveSync</span>
      <nav>
        <a href="/">Home</a>
        <a href="/privacy">Privacy Policy</a>
        <a href="/terms">Terms of Service</a>
      </nav>
    </footer>
  )
}

const features = [
  ['Both ways, automatically', 'Add or change a file in a linked Mac folder and it’s on Drive in seconds. Add one on Drive and it shows up on your Mac. Subfolders come along too.'],
  ['Lives in your menu bar', 'One small cloud icon tells you everything: up to date, syncing, paused, offline, or needs attention. No Dock icon, no windows in your way.'],
  ['Private by design', 'Files go straight between your Mac and Google. DriveSync has no servers, no analytics, and only works inside the folders you link.'],
  ['Nothing is lost', 'If a file changes on both sides, your Mac’s version wins and Drive keeps the older one in its version history. Deletions go to the Trash, never straight to oblivion.'],
]

function Home() {
  return (
    <main>
      <section className="hero">
        <img className="hero-icon" src="/icon.png" alt="DriveSync app icon" />
        <h1>Your Mac folders,<br />backed up to Drive</h1>
        <p className="lead">
          Pick a folder on your Mac. Anything you add or change is kept in sync with the matching folder in your
          Google Drive, both ways, quietly, from the menu bar.
        </p>
        <p className="meta">Free · macOS 14 Sonoma or later</p>
        <img className="shot" src="/dropdown.png" alt="The DriveSync menu open in the macOS menu bar, showing synced folders and recent uploads" />
      </section>

      <section className="grid">
        {features.map(([t, d]) => (
          <div className="card" key={t}><h3>{t}</h3><p>{d}</p></div>
        ))}
      </section>

      <section className="how">
        <h2>Set up in three steps</h2>
        <ol>
          <li><b>Sign in with Google.</b> Your browser opens Google’s own sign-in page. DriveSync never sees your password.</li>
          <li><b>Link a folder.</b> Choose a Mac folder and the Drive folder to pair it with (an existing one, or a new one). Decide what happens when you delete a file.</li>
          <li><b>Start syncing.</b> That’s it. DriveSync starts with your Mac and keeps the folder backed up.</li>
        </ol>
        <img className="shot" src="/link.png" alt="The DriveSync 'Link a folder' window" />
      </section>
    </main>
  )
}

function Privacy() {
  return (
    <main className="doc">
      <h1>Privacy Policy</h1>
      <p className="meta">Last updated {UPDATED}</p>

      <p>
        DriveSync is a macOS app that keeps folders you choose on your Mac in sync with folders in your own Google Drive.
        This policy explains what information DriveSync accesses and what it does with it. The short version:
        <b> your files move directly between your Mac and your Google Drive. DriveSync has no servers and collects nothing.</b>
      </p>

      <h2>Information DriveSync accesses</h2>
      <ul>
        <li>
          <b>Your Google Drive files</b> (scope <code>https://www.googleapis.com/auth/drive</code>). Google grants
          this permission for the whole Drive, but DriveSync only uses it inside the Drive folders you link: it
          finds the linked folder by name, lists the files in it, downloads new or changed files to your Mac,
          uploads files from your Mac, and moves files to the Drive Trash only if you choose that option.
          It does not open, read, or change anything outside the folders you link.
        </li>
        <li>
          <b>Your Google account email address</b>, read once after sign-in so the app can show which account
          is connected.
        </li>
        <li>
          <b>Files in the Mac folders you link</b>, which DriveSync reads to upload them to your Drive, and writes to when files are added or changed on Drive.
        </li>
      </ul>

      <h2>How the information is used</h2>
      <p>
        Only to provide the app’s single feature: keeping your chosen folders in sync between your Mac and your
        Google Drive, and showing you sync status. DriveSync does not use your data for advertising, analytics, profiling, or training
        AI or machine-learning models.
      </p>

      <h2>Where it is stored</h2>
      <ul>
        <li>Your Google sign-in token is stored in the macOS Keychain on your Mac.</li>
        <li>App settings and the list of synced files are stored on your Mac in <code>~/Library/Application Support/DriveSync</code>.</li>
        <li>Your files travel directly between your Mac and Google over encrypted HTTPS connections.</li>
      </ul>
      <p>DriveSync has no backend server. The developer never receives, stores, or has access to your files, your email address, or your Google credentials.</p>

      <h2>Sharing</h2>
      <p>
        DriveSync does not sell, rent, or share your information with anyone. The only party your data is sent
        to is Google, as required to sync files with your Google Drive.
      </p>

      <h2>Google API Services User Data Policy</h2>
      <p>
        DriveSync’s use and transfer to any other app of information received from Google APIs will adhere to
        the <a href="https://developers.google.com/terms/api-services-user-data-policy">Google API Services User Data Policy</a>,
        including the Limited Use requirements.
      </p>

      <h2>Removing your data</h2>
      <ul>
        <li>Sign out in DriveSync (Settings → Account) to delete the token from your Mac and revoke access.</li>
        <li>You can also revoke access anytime at <a href="https://myaccount.google.com/permissions">myaccount.google.com/permissions</a>.</li>
        <li>Deleting the app and the folder <code>~/Library/Application Support/DriveSync</code> removes all local data.</li>
        <li>Files already synced stay in your Google Drive and on your Mac until you delete them.</li>
      </ul>

      <h2>Children</h2>
      <p>DriveSync is not directed at children under 13 and does not knowingly collect information from them.</p>

      <h2>Changes</h2>
      <p>If this policy changes, the updated version will be posted on this page with a new “Last updated” date.</p>

      <h2>Contact</h2>
      <p>Questions about this policy can be sent to the support email shown on DriveSync’s Google sign-in screen.</p>
    </main>
  )
}

function Terms() {
  return (
    <main className="doc">
      <h1>Terms of Service</h1>
      <p className="meta">Last updated {UPDATED}</p>

      <p>By installing or using DriveSync (“the app”), you agree to these terms.</p>

      <h2>1. What the app does</h2>
      <p>
        DriveSync keeps folders you choose on your Mac in sync with folders in your Google Drive. It is provided
        free of charge for personal use.
      </p>

      <h2>2. Your account and content</h2>
      <p>
        You need your own Google account. You are responsible for the files you choose to sync and for
        complying with <a href="https://policies.google.com/terms">Google’s Terms of Service</a> and your Google
        Drive storage limits. You keep all rights to your files. DriveSync claims no ownership of them.
      </p>

      <h2>3. Acceptable use</h2>
      <p>Don’t use the app to upload content you don’t have the right to store, or in any way that breaks the law or Google’s policies.</p>

      <h2>4. Keep your own backups</h2>
      <p>
        DriveSync is a convenience tool, not a guaranteed backup service. Syncing can fail, be delayed, or be
        incomplete, and changes or deletions on one side are copied to the other (for example because of network problems, Drive storage limits, or changes to Google’s
        services). Keep independent copies of anything important.
      </p>

      <h2>5. No warranty</h2>
      <p>
        The app is provided “as is” and “as available”, without warranties of any kind, express or implied,
        including merchantability, fitness for a particular purpose, and non-infringement.
      </p>

      <h2>6. Limitation of liability</h2>
      <p>
        To the maximum extent permitted by law, the developer is not liable for any indirect, incidental,
        special, or consequential damages, or for any loss of data, arising from your use of or inability to
        use the app.
      </p>

      <h2>7. Third-party services</h2>
      <p>
        The app relies on Google Drive and Google sign-in, which are operated by Google and governed by Google’s
        own terms and privacy policy. See also the <a href="/privacy">DriveSync Privacy Policy</a>.
      </p>

      <h2>8. Ending use</h2>
      <p>You can stop using DriveSync at any time by signing out and deleting the app.</p>

      <h2>9. Changes</h2>
      <p>These terms may be updated. Changes are posted on this page with a new “Last updated” date. Continuing to use the app means you accept them.</p>

      <h2>10. Contact</h2>
      <p>Questions about these terms can be sent to the support email shown on DriveSync’s Google sign-in screen.</p>
    </main>
  )
}

const pages = { '/privacy': Privacy, '/terms': Terms }

function App() {
  const path = window.location.pathname.replace(/\/+$/, '') || '/'
  const Page = pages[path] ?? Home
  document.title = { '/privacy': 'Privacy Policy · DriveSync', '/terms': 'Terms of Service · DriveSync' }[path] ?? 'DriveSync'
  return <><Nav /><Page /><Footer /></>
}

createRoot(document.getElementById('root')).render(<StrictMode><App /></StrictMode>)
