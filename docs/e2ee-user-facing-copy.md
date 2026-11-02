# End-to-end encryption: draft user-facing copy

**Status: DRAFT for the owner to review and edit.** Not legal advice; have it
checked before publishing as Terms. Written for the app's end users (plain
language); the owner decides what to publish and where. Bracketed `[...]` items
need your decision. Wizard/UI strings are marked `UI:`.

## 1. What encryption does for you

Your debts, payments, settings and notes are encrypted **in your browser**
before they are saved. The server stores only scrambled data it cannot read. It
never receives your passphrase, your passkey, or your recovery key. That means a
copy of our database, an old backup, or someone with access to our hosting
cannot read your financial details.

## 2. What it does not do (please read)

- **If you forget your passphrase and lose your recovery key (and have no
  passkey), your data cannot be recovered. By anyone. Including us.**
- Anyone who can run code in your browser, or who controls the website's code,
  could in principle capture what you type. We keep the site's code small and
  locally hosted, but no web app can promise more than that.
- Anyone using your unlocked browser or device can see your data. Lock the app
  when you step away. "Remember this device" makes this easier and less safe; use
  it only on devices you control.
- A weak passphrase can be guessed offline by someone who obtains our database.
  Use a long passphrase (four or more random words) or a passkey.
- We can still see that you have an account, when you sign in, and roughly how
  large your encrypted data is.

## 3. Your recovery key

`UI:` **Save your recovery key now.** It is the only way back in if you forget
your passphrase or lose your passkey. We cannot show it to you again. Store it
somewhere safe and offline (a password manager, or printed and locked away).
To continue, type the last group of the key below to show you have it.

`UI:` [ ] I have saved my recovery key somewhere safe.

## 4. Unlocking

`UI:` Enter your passphrase, use your passkey, or enter your recovery key.
`UI (failure):` That didn't unlock your data. Check your passphrase and try
again. *(One generic message; we deliberately don't say why.)*
`UI (recovery typo):` That recovery key doesn't look right. Check each group for
typos. *(Shown only when the key's built-in checksum fails.)*
`UI (too many tries):` Please wait a few seconds before trying again.

## 5. Passkeys

Passkeys let you unlock with your fingerprint, face, or device PIN. They depend
on your browser and device supporting it, and a passkey stored on one device may
not exist on another. **Keep a second unlock method (a passphrase or your
recovery key).** `UI:` Passkeys aren't available in this browser. [Use a
passphrase instead.]

## 6. Remember this device

`UI:` Stay unlocked on this device? Anyone who can open this browser profile will
be able to open your data. You can turn this off at any time with "Forget this
device". The app still locks after [15] minutes of inactivity.

## 7. Changing or removing unlock methods

`UI:` You must always keep at least one way to unlock. Changing your passphrase
does not re-encrypt your data; it only replaces how it's unlocked.

## 8. Start over

`UI:` **This permanently deletes your encrypted data.** If you have lost every
way to unlock it, this is the only option, and your old data cannot be
recovered. Type DELETE to confirm.

## 9. First sign-in after we turn encryption on (existing users)

`UI:` **Lock down your financial data.** We've added a new privacy feature. Your
debts, payments and retirement details will be locked (encrypted) so that **only
you can read them**. Not even we can. **What you need to do:** choose a
passphrase (about a minute); you'll use it to unlock the app, and you'll get a
recovery key to save in case you forget it. **Your data stays safe:** we make a
locked copy first and check that it matches; only then do we remove the old
copy. You'll need to finish this before you can use the app again.
Button: **Lock my data**.

`UI (shared workspace):` **Other people will lose access.** This workspace is
shared with [names]. After you encrypt it, only you can open its data. They keep
their own workspaces but will no longer see this one. [ ] I understand that
[names] will lose access to this workspace's financial data.
*(Export your CSV first if they need a copy.)*

`UI (after success):` Your data is encrypted and your old unencrypted copy has
been deleted from our database. **Copies may remain in our hosting provider's
backups until they expire (about [N] days).** `[owner: confirm retention period]`

`UI (changed during setup):` Something changed while we were encrypting your
data, so we stopped before deleting anything. Please try again.

## 10. Terms clause (draft)

> **Encryption and data recovery.** The service offers optional/required [pick
> one] end-to-end encryption. Your encrypted data can be decrypted only with
> your passphrase, passkey, or recovery key, which we do not possess and cannot
> reset or recover. If you lose all of them, your data is permanently
> inaccessible. We are not responsible for loss of access resulting from lost
> credentials. Our database backups contain only encrypted data and are of no
> use to a user who has lost every unlock method. Backups made before you
> encrypted your data may contain unencrypted copies until they expire in the
> ordinary course [period].
>
> **Limits of the protection.** End-to-end encryption protects stored data
> against access by us, our hosting providers, and anyone who obtains our
> database. It does not protect against malware on your device, a compromised
> browser, or an attacker who controls the code the service delivers to your
> browser.
>
> **Shared workspaces.** Encrypting a shared workspace gives access to its
> financial data only to the person who encrypts it. [Other members lose access
> to that workspace's financial data.]

## 11. Open questions for the owner

1. Is encryption **required** for everyone after the switch (current plan) or
   offered as opt-in? The copy above assumes required.
2. Backup retention period to quote (Render/Postgres) for section 9 and the Terms.
3. Idle lock default (draft says 15 minutes).
4. Do you want a short support/contact line for "I'm locked out"? (We can only
   say "we cannot help recover data", but a contact avoids a dead end.)
