---
description: "Every task in the win32-toolkit guide as a question, with a link to the section that answers it."
---

# Find a task

Find your win32-toolkit question and follow the link. Most answers show the menu ([`Show-Win32Toolkit`](reference/Show-Win32Toolkit.md)) first and the command line second.

## Set up

### Install the toolkit

- [Can my PC run the toolkit](install.md#check-your-pc)?
- [What does the toolkit cost](how-it-works.md#how-long-it-takes-and-what-it-costs)?
- [How do I turn on Windows Sandbox](install.md#turn-on-windows-sandbox)?
- [How do I install PowerShell 7](install.md#install-powershell-7)?
- [How do I install the toolkit](install.md#install-win32-toolkit)?

### First start

- [How do I start the menu](install.md#start-the-menu-for-the-first-time)?
- [Which base folder should I choose](install.md#choose-your-base-folder)?
- [How do I read the system check](install.md#read-the-system-check)?
- [What does each menu item do](menu.md#the-main-menu)?
- [How do I change a setting](settings.md#change-a-setting)?
- [Where are my files](settings.md#the-base-folder-layout)?

### Update, move or remove

- [How do I update the toolkit](maintain-toolkit.md#update-win32-toolkit)?
- [How do I turn off the update check](maintain-toolkit.md#turn-off-the-update-check)?
- [Which PSAppDeployToolkit version do projects get](maintain-toolkit.md#choose-the-psadt-version-for-new-projects)?
- [How do I move the base folder](maintain-toolkit.md#move-or-change-the-base-folder)?
- [How do I fix apps from win32-toolkit 1.1.6 or older](maintain-toolkit.md#fix-apps-that-are-already-in-intune)?
- [How do I remove the toolkit](maintain-toolkit.md#remove-the-toolkit)?

## Org templates

- [How do I create my first org template](org-templates.md#create-the-template)?
- [How do I edit, copy or delete a template](org-templates.md#view-edit-copy-or-delete-a-template)?
- [The toolkit asks to update a template. What now](org-templates.md#when-the-toolkit-asks-to-update-a-template)?
- [When do dialogs appear on devices](org-templates.md#when-dialogs-appear-on-devices)?
- [How do I add a logo, hook scripts or an extension module](org-template-files.md#turn-on-the-files-in-the-template)?

## Package apps

### From winget

- [How do I package an app from winget](packaging.md#run-the-wizard)?
- [How do I choose the installer technology](packaging.md#installer-technology)?
- [What do the download warnings mean](packaging.md#warnings-after-the-download)?

### Not in winget

- [How do I package an app that is not in winget](manual-apps.md#package-an-easy-app)?
- [The EXE has no silent switch: what now](manual-apps.md#package-an-advanced-app)?
- [Where do I write the install code](manual-apps.md#write-the-install-code)?
- [How do I package an MSIX or APPX](manual-apps.md#msix-and-appx-packages)?
- [How do I finish or refresh a project later](manual-apps.md#finish-or-refresh-a-project-later)?
- [How do I test an update of an app that is not in winget](manual-apps.md#test-an-update-of-a-manual-app)?

### Existing projects

- [What is inside a project](settings.md#inside-a-project)?
- [Can I change a project by hand](projects.md#change-a-project-by-hand)?
- [How do I repeat the install capture](projects.md#run-the-install-capture-again)?
- [How do I re-create a project](projects.md#re-create-a-project)?
- [A build stopped halfway. What now](projects.md#recover-from-a-stopped-build)?

## Test packages

### Run a test

- [How do I test install and uninstall](testing.md#run-an-install-and-uninstall-test)?
- [Should my test be interactive or unattended](testing.md#interactive-or-unattended)?
- [Where should the test run](testing.md#choose-where-the-test-runs)?
- [How do I test as Intune does](testing.md#test-as-intune-does)?
- [Why was my test not started](testing.md#when-a-test-is-not-started)?
- [Can I test while I build](testing.md#test-while-you-build)?

### Updates and results

- [How do I test an update](testing.md#test-an-update-from-an-older-version)?
- [Which technology should the old version use](testing.md#choose-the-installer-technology-of-the-old-version)?
- [How do I read the result](testing.md#read-the-result)?
- [Where are the logs](exit-codes.md#where-to-find-logs)?

## Build and publish

### Build and connect

- [How do I build the `.intunewin` package](build-intunewin.md#build-the-package)?
- [What does my account need](intune-connection.md#what-your-account-needs)?
- [How do I connect to the right tenant](intune-connection.md#connect)?
- [How do I work for several customers](intune-connection.md#work-for-several-customers)?
- [How do I sign out](intune-connection.md#sign-out)?

### Publish to Intune

- [How do I publish my app](publishing.md#publish-your-app)?
- [Can I try a publish without changing Intune](publishing.md#try-it-first-with-a-dry-run)?
- [What if the app cannot be detected](publishing.md#apps-that-cannot-be-detected-automatically)?
- [What must I finish in the Intune admin center](publishing.md#finish-in-the-intune-admin-center)?
- [Can I give my customer a summary](publishing.md#give-your-customer-a-one-page-summary)?
- [Can I build, test and publish in one run](publishing.md#next-time-do-it-all-in-one-run)?
- [The publish failed. How do I clean up](publishing.md#if-the-publish-fails)?

## Keep apps up to date

- [How do I ship a new version](new-version.md#the-steps-at-a-glance)?
- [Do I need an update app too](new-version.md#install-app-update-app-or-both)?
- [How do I replace the old app in Intune](new-version.md#replace-the-old-app-in-intune)?
- [Does the next version keep the prior-install rules](new-version.md#with-prior-install-rules)?
- [How do I keep Enforce rules on the next version](prior-installs-enforce.md#keep-enforce-rules-on-the-next-version)?
- [What is a technology switch](packaging.md#when-a-test-reports-a-technology-switch)?

## Dependencies

- [How do I add a dependency](dependencies.md#add-a-dependency-when-you-create-the-app)?
- [How do I change a project's dependencies](dependencies.md#change-the-dependencies-of-a-project)?
- [Should Intune install a dependency or only check for it](dependencies.md#install-it-first-or-only-check-for-it)?
- [What do tests do with dependencies](dependencies.md#dependencies-in-tests)?
- [How do I publish an app with dependencies](dependencies.md#publish-an-app-with-dependencies)?
- [How do I change dependencies of a published app](dependencies.md#change-the-dependencies-of-an-app-in-intune)?
- [How do I remove all dependencies](dependencies.md#remove-all-dependencies)?

## Prior installs

### Rules and captures

- [Devices already have the app. What now](prior-installs.md#when-you-need-this)?
- [What do Block, Enforce and Report mean](prior-installs.md#block-enforce-and-report)?
- [How do I capture the other installer technologies](prior-installs.md#capture-the-other-installer-technologies)?
- [How do I review the proposals](prior-installs.md#review-the-proposals)?
- [How do I apply proposals with a command](prior-installs.md#apply-proposals-from-the-command-line)?
- [How do I see, change or remove rules](prior-installs.md#see-change-or-remove-rules)?
- [How do I capture more versions](prior-installs.md#capture-more-versions-or-capture-by-hand)?

### Enforce rules

- [When can a rule remove a prior install](prior-installs-enforce.md#when-enforce-is-possible)?
- [How do I approve a proposal as Enforce](prior-installs-enforce.md#approve-a-proposal-as-enforce)?
- [How do I prove an Enforce rule](prior-installs-enforce.md#prove-the-rule)?
- [What takes a proof away](prior-installs-enforce.md#what-takes-a-proof-away)?
- [How do I record or remove a waiver or an acknowledgement](prior-installs-enforce.md#acknowledgements-and-waivers)?
- [Can a failed update test give me a rule](prior-installs-enforce.md#get-a-rule-from-a-failed-update-test)?
- [How do I type a rule by hand](prior-installs-enforce.md#type-a-rule-by-hand)?

### On devices

- [How do I publish a project with rules](prior-installs.md#build-and-publish-a-project-with-rules)?
- [How do I roll out rules safely](prior-installs-devices.md#roll-out-safely)?
- [How do I stop every removal on devices](prior-installs-devices.md#stop-all-removals-with-the-kill-switch)?
- [Devices fail after the rollout. What now](prior-installs-devices.md#incident-runbook)?
- [What do the prior-install exit codes mean](exit-codes.md#prior-install-codes)?
- [How do I clear a 69110](prior-installs-devices.md#clear-a-69110)?

## Hyper-V test VM

### Build the VM

- [When do I need the Hyper-V test virtual machine (VM)](hyperv-vm.md#when-you-need-the-test-vm)?
- [What does my PC need](hyperv-vm.md#prepare-your-pc)?
- [How do I build the test VM](hyperv-vm.md#build-the-vm)?
- [How do I prepare Windows inside the VM](hyperv-vm.md#prepare-windows-inside-the-vm)?
- [Can I use my own virtual disk](hyperv-vm.md#use-your-own-virtual-disk)?
- [How do I make the VM my default](hyperv-vm.md#make-the-test-vm-your-default)?
- [Is the VM ready](hyperv-vm.md#check-that-the-vm-is-ready)?

### Fast and safe

- [How do I re-take the checkpoint](hyperv-vm.md#re-take-the-checkpoint)?
- [How do I make Hyper-V tests faster](hyperv-vm.md#make-hyper-v-tests-faster)?
- [How do I keep the VM safe](hyperv-vm.md#keep-the-vm-safe)?
- [How do I change processors or memory](hyperv-vm-care.md#change-processors-or-memory)?
- [How do I choose another test VM](hyperv-vm-care.md#choose-another-test-vm)?
- [Can one PowerShell window use another VM](hyperv-vm-care.md#use-another-vm-in-one-powershell-window)?
- [Another window uses the VM. What now](hyperv-vm-care.md#when-another-window-is-using-the-vm)?

### Repair or remove

- [How do I reset the VM by hand](hyperv-vm-care.md#reset-the-vm-by-hand)?
- [How do I repair a broken VM](hyperv-vm-care.md#repair-a-broken-vm)?
- [How do I fix a wrong VM password](hyperv-vm-care.md#fix-a-wrong-vm-password)?
- [How do I rebuild the VM](hyperv-vm-care.md#rebuild-the-vm)?
- [How do I remove the VM](hyperv-vm-care.md#remove-the-vm)?

## Scripts and automation

- [How do I run the toolkit without the menu](automation.md#answer-every-question-with-a-parameter)?
- [How does a script check the result](automation.md#check-the-result)?
- [Can tests run with nobody watching](automation.md#tests-without-a-person)?
- [Can a script publish to Intune](automation.md#publish-from-a-script)?
- [Which environment variables can I set](automation.md#environment-variables)?

## Still stuck

- [What does this message mean](troubleshooting.md)?
- [What does an exit code mean](exit-codes.md)?
- [What can the toolkit not do](known-limits.md#limits-and-workarounds)?
- [What does this word mean](glossary.md)?
