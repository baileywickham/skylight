# Personal tap formula (the skylight repo doubles as the tap):
#   brew tap baileywickham/skylight git@github.com:baileywickham/skylight.git
#   brew install --HEAD baileywickham/skylight/skylight
#
# Head-only: the repo is private with no versioned releases, so the formula
# builds from main over the user's SSH credentials.
#
# Deliberately NOT `brew services`: TCC keys a bare binary's grants to its
# path, and HEAD kegs move on every reinstall — grants would be lost each
# upgrade. Instead post_install reuses the repo's own packaging design
# (signed SkylightService.app in ~/Applications + LaunchAgent), whose bundle
# identity + stable signature keep Accessibility/Screen Recording grants
# across upgrades. See scripts/install-launchagent.sh.
class Skylight < Formula
  desc "Local computer-use daemon: AX trees, screenshots, and UI actuation for macOS apps"
  homepage "https://github.com/baileywickham/skylight"
  head "git@github.com:baileywickham/skylight.git", branch: "main", using: :git

  depends_on :macos

  def install
    # SwiftPM's own sandbox conflicts with Homebrew's build sandbox.
    system "swift", "build", "-c", "release", "--disable-sandbox"

    bin.install ".build/release/skylight"
    bin.install "scripts/skylight-run"
    # skylight-run detects the keg layout by libexec/ts (vs ts/ in the repo).
    # node_modules is installed lazily on first run with the user's node —
    # not a brew dependency, so an nvm-managed node keeps working.
    libexec.install "ts"

    # Keg mirrors the repo layout install-launchagent.sh expects:
    # packaging/ + build/SkylightService.app + scripts/.
    app = prefix/"build/SkylightService.app"
    (app/"Contents/MacOS").mkpath
    cp "packaging/Info.plist", app/"Contents/Info.plist"
    cp ".build/release/SkylightService", app/"Contents/MacOS/SkylightService"
    prefix.install "packaging"
    (prefix/"scripts").install "scripts/install-launchagent.sh"
  end

  def post_install
    app = prefix/"build/SkylightService.app"
    identity = signing_identity
    if identity.nil?
      opoo <<~EOS
        No codesigning identity found — skipped signing and LaunchAgent setup.
        Create one (Keychain Access > Certificate Assistant, name "Skylight Dev",
        type Code Signing) or import an Apple identity, then:
          brew postinstall skylight
      EOS
      return
    end
    ohai "Signing SkylightService.app with '#{identity}'"
    system "codesign", "--force", "--sign", identity,
           "--identifier", "com.skylight.SkylightService", app.to_s
    system "codesign", "--verify", "--strict", app.to_s
    # Copies the app to ~/Applications and bootstraps the LaunchAgent, so TCC
    # attributes grants to the launchd-launched service itself.
    system "bash", (prefix/"scripts/install-launchagent.sh").to_s
  end

  # Stable identity preference: the repo-convention self-signed cert first,
  # then Apple identities (Developer ID outlives yearly Apple Development
  # certs). SKYLIGHT_SIGNING_IDENTITY overrides when Homebrew passes it through.
  def signing_identity
    override = ENV.fetch("SKYLIGHT_SIGNING_IDENTITY", nil)
    return override unless override.to_s.empty?

    out = Utils.safe_popen_read("security", "find-identity", "-v", "-p", "codesigning")
    ["Skylight Dev", "Developer ID Application", "Apple Development"].each do |name|
      found = out[/"(#{Regexp.escape(name)}[^"]*)"/, 1]
      return found if found
    end
    nil
  end

  def caveats
    <<~EOS
      One-time (and after signing-identity changes): grant the service its TCC
      permissions in System Settings > Privacy & Security:
        - Accessibility     -> add ~/Applications/SkylightService.app
        - Screen Recording  -> add ~/Applications/SkylightService.app
      then restart it: launchctl kickstart -k gui/$(id -u)/com.skylight.SkylightService

      Drive it with skylight-run (see `skylight-run --help`); manage the
      actuation allowlist with `skylight approve "<App>"`.
    EOS
  end

  test do
    assert_match "accessibility", shell_output("#{bin}/skylight doctor")
  end
end
