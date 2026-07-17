# Connecting to Intune

Publishing signs you in automatically, so for a single tenant you may never think about this page.
It matters when you package for **more than one customer**, because then the question stops being
*"am I signed in?"* and becomes *"whose Intune am I about to write to?"*

## Why the account name is not the answer

If you are a consultant, your sign-in looks the same everywhere. `mg@cloudflow.be` is `mg@cloudflow.be`
whether you are a guest in Contoso's tenant or Fabrikam's. So an "signed in as ..." line tells you who
you are and nothing about where the app is going.

**The tenant is the thing that decides.** That is why every connection banner leads with the tenant
name, and why the toolkit wants you to pin one.

## Pin the tenant on the org template

An org template already carries everything else that is per-customer, so it carries the tenant too:

```powershell
Invoke-Win32Toolkit -NewTemplate -TemplateName 'Contoso'
# ... Intune tenant (blank = unpinned): contoso.onmicrosoft.com
```

Once pinned, two things follow automatically:

- **Connecting for that template goes to that tenant.** A session for a different customer is torn
  down and re-established rather than reused.
- **Publishing verifies it, and refuses on a mismatch.** Not a warning. An error, before anything is
  uploaded.

The pin is copied into the project when it is configured, so it still applies when you publish a
project on its own later, with no template loaded.

!!! warning "Unpinned templates cannot be checked"

    If a template has no tenant, the toolkit does not know which one is correct. It will warn you and
    continue, because silently doing nothing would be worse. Pin your templates.

## Connecting

From the TUI: **Microsoft Intune connection** on the main menu. It shows the current tenant, lets you
connect per customer, and signs out.

From the command line:

```powershell
# Connect to the tenant pinned on a template (recommended)
Connect-Win32ToolkitIntune -Template 'Contoso'

# Or a tenant directly
Connect-Win32ToolkitIntune -TenantId 'contoso.onmicrosoft.com'

# No browser on this host
Connect-Win32ToolkitIntune -Template 'Contoso' -UseDeviceAuthentication
```

You get a banner like this before anything is written:

```
  Tenant    : Contoso NV
  Domain    : contoso.onmicrosoft.com
  Tenant ID : 9f32a42e-6782-4b96-a4d3-e0828a29be11
  Account   : mg@cloudflow.be
  Template  : Contoso (matches)
  Scopes    : DeviceManagementApps.ReadWrite.All
  Session   : Process / Delegated
```

If the tenant name shows as unavailable, that is fine: reading the organisation name needs a directory
permission your account may not have, and the toolkit deliberately does not ask for more privilege than
it needs to publish. You still get the tenant ID, and every guard still works.

## Where the token lives

| `-ContextScope` | Token lives | Use when |
|---|---|---|
| `Process` (default in the TUI) | This session only. Nothing on disk. | You work across several customers. A token that cannot outlive the session cannot be silently reused next week. |
| `CurrentUser` | Cached on disk, survives restarts. | You only ever touch one tenant and want to sign in less. |

## Signing out

```powershell
Disconnect-Win32ToolkitIntune
```

**Be clear about what this does.** It clears the token *this toolkit* holds, so the next publish must
sign in again. It does **not** sign you out of Entra: your browser session is untouched, so the next
connect may complete with no prompt and land straight back on the same tenant. That is the identity
provider's behaviour, not something this command can revoke.

So do not lean on disconnect to keep customers apart. The things that actually do that are:

1. **Pinning the tenant** on the template, which publish then verifies and refuses to violate.
2. **`-ContextScope Process`**, so no token outlives the session.

Disconnect is a convenience. The pin is the control.

## Permissions

The toolkit requests the least it needs to do the job:

| Scope | For |
|---|---|
| `DeviceManagementApps.ReadWrite.All` | Create the Win32 app, upload its content, set detection rules, categories, and relationships. |

The tenant *name* in the banner comes from a read of `/organization`. If your account cannot read it,
the banner shows the tenant ID instead and nothing else changes. Nothing here grants the toolkit any
write access beyond apps.

## Next steps

- [Publishing to Intune](publishing.md)
- [Org templates](org-templates.md)
