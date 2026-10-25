# Main menu and keyboard shortcuts

Decoded from `Contents/Resources/Base.lproj/MainMenu.nib` with REA's Interface Builder decoder. Order within a menu follows nib object IDs, not on-screen order. *(hidden)* items exist in the nib but are hidden by default (usually feature-flagged or alternates). Several features also register shortcuts at runtime via the `KeyBindings` module, so this list is not exhaustive.

### File

| Item | Shortcut | Action selector |
|---|---|---|
| Boost Gallery *(hidden)* |  | `openBoostGallery:` |
| Open Command Bar | ⌘L | `toggleOpenOmnibox:` |
| Capture… | ⇧⌘2 | `capturePage:` |
| New Profile |  | `newProfile:` |
| Edit Boost *(hidden)* |  | `editBoost:` |
| New Little Arc Window | ⌥⌘N | `newLittleBrowserWindow:` |
| Close Window | ⇧⌘W | `closeWindow:` |
| Share… |  | `share:` |
| New Window | ⌘N | `newWindow:` |
| New Note | ⌃⇧N | `newNote:` |
| Restore Last Closed Tab | ⇧⌘T | `reopenLastTab:` |
| New Tab… | ⌘T | `newWindowForTab:` |
| New Boost *(hidden)* |  | `newBoost:` |
| Print | ⌘P | `printPage:` |
| Capture in Portrait Mode |  | `capturePrettyScreenshot:` |
| Archive Tab | ⌘W | `closeCurrentItem:` |
| New Incognito Window | ⇧⌘N | `newIncognitoWindow:` |
| Send to Dia |  | `sendCurrentTabToDia:` |
| New Legacy Boost (Advanced) *(hidden)* |  | `newLegacyBoost:` |
| Save Page As | ⇧⌘S | `save:` |
| New Note (in Split) *(hidden)* | ⌃⌥N | `newNoteInSplitView:` |
| Capture Full Page |  | `captureFullPage:` |
| New Easel | ⌃⇧E | `newEasel:` |
| Blank Window | ⌃⌘N | `blankWindow:` |

### View

| Item | Shortcut | Action selector |
|---|---|---|
| Show/Hide Sidebar | ⌘S | `toggleArcSidebar:` |
| Zoom Out | ⌘- | `zoomOut:` |
| Add Split View | ⌃⇧= | `addSplitPanel:` |
| Close this Split Pane | ⌃⇧- | `closeFocusedSplitViewPanel:` |
| Enter/Exit Full Screen | ⌃⌘F | `toggleFullScreen:` |
| Stop Loading | ⌘. | `stopLoadingCurrentTab:` |
| Expand Pinned Section *(hidden)* |  | `expandPinnedSection:` |
| Expand Current Split |  | `maximizeCurrentSplitViewPane:` |
| Refresh the Page | ⌘R | `reloadPage:` |
| Zoom to Actual Size | ⌘0 | `resetZoom:` |
| Reveal Current Tab *(hidden)* | ⌃Space | `focusSidebar:` |
| Collapse Pinned Section *(hidden)* |  | `collapsePinnedSection:` |
| Force Refresh the Page | ⇧⌘R | `forceReloadPage:` |
| Zoom In | ⌘+ | `zoomIn:` |
| Clear Cache and Refresh |  | `clearCacheAndRefresh:` |
| Show/Hide Toolbar *(hidden)* | ⇧⌘D | `toggleArcToolbar:` |
| Separate Page from Split View |  | `separateTabFromSplitView:` |
| Exit | ⎋ | `exit:` |
| Cast |  | `cast:` |
| Clear Cookies and Refresh |  | `clearCookiesAndRefresh:` |
| Zoom Out *(hidden)* | ⇧⌘- | `zoomOut:` |
| Zoom In *(hidden)* | ⌘= | `zoomIn:` |
| Zoom In *(hidden)* | ⌘= | `zoomIn:` |
| Appearance |  | `submenuAction:` |
| Developer |  | `submenuAction:` |

### Tabs

| Item | Shortcut | Action selector |
|---|---|---|
| New ChatGPT Message… *(hidden)* | ⌥⌘G | `gptMessage:` |
| Collapse All Folders *(hidden)* |  | `collapseAllFolders:` |
| Rename Current Item *(hidden)* |  | `rename:` |
| Expand All Folders *(hidden)* |  | `expandAllFolders:` |
| Cycle Tab Backward *(hidden)* | ⌃⌘← | `cycleTabBackward:` |
| Pin/Unpin Tab | ⌘D | `toggleSelectedItemsPinned:` |
| Tab Switcher (backward) *(hidden)* | ⌃⇧ | `cycleToPreviousRecentTab:` |
| Peek Email… *(hidden)* | ⇧⌘E | `peekEmail:` |
| Reset all tabs in this Space |  | `resetVisiblePinnedTabs:` |
| Clear Unpinned Tabs | ⇧⌘K | `clearExplore:` |
| Duplicate *(hidden)* |  | `duplicate:` |
| Reveal Tab in Sidebar |  | `revealCurrentTabInSidebar:` |
| Previous Tab | ⌥⌘↑ | `previousTab:` |
| Cycle Tab Forward *(hidden)* | ⌃⌘→ | `cycleTabForward:` |
| New Folder… | ⇧⌘N | `newList:` |
| Tab Switcher (forward) *(hidden)* | ⌃⇥ | `cycleToNextRecentTab:` |
| Join Meeting *(hidden)* | ⌃⌘J | `joinLiveMeeting:` |
| Reset Tab to Original URL *(hidden)* |  | `resetTab:` |
| Next Tab | ⌥⌘↓ | `nextTab:` |
| Open Little Arc or Peek in… | ⌘O | `openInCurrentSpace:` |
| New Tab… | ⌘T | `newWindowForTab:` |

### Archive

| Item | Shortcut | Action selector |
|---|---|---|
| Go Forward | ⌘] | `navigateTabForward:` |
| Go Back *(hidden)* | ⌘← | `navigateTabBackArrow:` |
| View Archive |  | `showArchive:` |
| Go Back | ⌘[ | `navigateTabBack:` |
| View History | ⌘Y | `showAllHistory:` |
| Clear Archive |  | `clearArchive:` |
| Go Forward *(hidden)* | ⌘→ | `navigateTabForwardArrow:` |

### Troubleshooting

| Item | Shortcut | Action selector |
|---|---|---|
| Cancel Trace *(hidden)* |  | `cancelTrace:` |
| Record Trace |  | `recordTrace:` |
| Open Task Manager |  | `openTaskManager:` |
| Copy Arc Info |  | `copyArcInfo:` |
| Reveal Arc Data |  | `revealArcData:` |

### Spaces

| Item | Shortcut | Action selector |
|---|---|---|
| Change Profile |  | `changeProfileForCurrentSpace:` |
| Rename Space |  | `renameFocusedSpace:` |
| Manage Spaces… |  | `toggleSpaceManager:` |
| Next Space | ⌥⌘→ | `nextSpace:` |
| Previous Space | ⌥⌘← | `previousSpace:` |
| New Space… |  | `newSpace:` |
| Edit Theme… |  | `editSpaceTheme:` |

### Help

| Item | Shortcut | Action selector |
|---|---|---|
| Visit Help Center |  | `visitHelpCenter:` |
| Essential Keyboard Shortcuts |  | `keyboardShortcutsEDU:` |
| Getting Started |  | `showWelcomeToArc:` |
| Export Arc Notes |  | `exportArcNotes:` |
| Contact the Team |  | `contactTheTeam:` |
| Release Notes |  | `onSelectResource_releaseNotes:` |
| Restore Data |  | `presentRestoreDataFlow:` |
| Troubleshooting |  | `submenuAction:` |

### Arc

| Item | Shortcut | Action selector |
|---|---|---|
| About Arc |  | `orderFrontStandardAboutPanel:` |
| Set as Default Browser |  | `setAsDefaultBrowser:` |
| Show All |  | `unhideAllApplications:` |
| Privacy Policy |  | `showPrivacyPolicy:` |
| Share Arc |  |  |
| Hide Arc | ⌘H | `hide:` |
| Hide Other Windows | ⌥⌘H | `hideOtherApplications:` |
| Quit Arc | ⌘Q | `userQuitApp:` |
| Preferences… | ⌘, | `showPreferences:` |
| Check for Updates… |  | `checkForUpdates:` |
| Import from Another Browser… |  |  |
| Sign Out |  | `signOut:` |
| Services |  | `submenuAction:` |

### Edit

| Item | Shortcut | Action selector |
|---|---|---|
| Redo | ⇧⌘Z | `redo:` |
| Copy URL as Markdown | ⌥⇧⌘C | `copyCurrentURLAsMarkdown:` |
| Select All | ⌘A | `selectAll:` |
| Paste and Match Style | ⇧⌘V | `pasteAsPlainText:` |
| Copy URL | ⇧⌘C | `copyCurrentURL:` |
| Paste | ⌘V | `paste:` |
| Cut | ⌘X | `cut:` |
| Copy URL as Quote | ⌃⇧⌘C | `copyCurrentURLAsQuote:` |
| Copy | ⌘C | `copyAction:` |
| Delete |  | `delete:` |
| Undo | ⌘Z | `undo:` |
| Find |  | `submenuAction:` |
| Spelling and Grammar |  | `submenuAction:` |
| Substitutions |  | `submenuAction:` |
| Transformations |  | `submenuAction:` |
| Speech |  | `submenuAction:` |
| Format |  | `submenuAction:` |

### Window

| Item | Shortcut | Action selector |
|---|---|---|
| View Downloads | ⇧⌘J | `toggleDownloads:` |
| View Library | ⇧⌘L | `toggleLibrary:` |
| View Media |  | `viewScreenshotsAndCaptures:` |
| View Boosts |  | `viewBoosts:` |
| Minimize Window | ⌘M | `performMiniaturize:` |
| View Easels & Notes |  | `viewEaselsAndNotes:` |
| Zoom |  | `performZoom:` |
| Bring All to Front |  | `arrangeInFront:` |

### Developer

| Item | Shortcut | Action selector |
|---|---|---|
| Developer Tools *(hidden)* |  | `toggleDevTools:` |
| Network Inspector |  | `networkInspector:` |
| View Source | ⌥⌘U | `viewSource:` |
| Toggle Developer Mode | ⌃D | `toggleDeveloperMode:` |
| JavaScript Console | ⌥⌘J | `javaScriptConsole:` |
| Inspect Elements | ⌥⌘C | `inspectElements:` |
| Developer Tools | ⌥⌘I | `toggleDevTools:` |
| Allow JavaScript from Apple Events |  | `allowJavascriptFromAppleEvents:` |

### Spelling

| Item | Shortcut | Action selector |
|---|---|---|
| Show Spelling and Grammar | ⌘: | `showGuessPanel:` |
| Correct Spelling Automatically |  | `toggleAutomaticSpellingCorrection:` |
| Check Document Now | ⌘; | `checkSpelling:` |
| Check Grammar With Spelling |  | `toggleGrammarChecking:` |
| Check Spelling While Typing |  | `toggleContinuousSpellChecking:` |

### ?

| Item | Shortcut | Action selector |
|---|---|---|
| Dark |  | `setDarkAppearance:` |
| Automatic |  | `setAutomaticAppearance:` |
| Light |  | `setLightAppearance:` |
| Item 1 |  |  |
| Item 2 |  |  |
| Item 3 |  |  |
| Websites, Easels, and Notes will use: |  |  |

### Find

| Item | Shortcut | Action selector |
|---|---|---|
| Find Previous | ⇧⌘G | `arc_performFindPanelAction:` |
| Jump to Selection | ⌘J | `arc_performFindPanelAction:` |
| Find… | ⌘F | `arc_performFindPanelAction:` |
| Find and Replace | ⌥⌘F | `arc_performFindPanelAction:` |
| Use Selection to Find |  | `arc_performFindPanelAction:` |
| Find Next | ⌘G | `arc_performFindPanelAction:` |

### Extensions

| Item | Shortcut | Action selector |
|---|---|---|
| Manage Extensions… |  | `navigateToChromeExtensionsPage:` |
| Add Extension… |  | `navigateToChromeWebStore:` |

### Main Menu

| Item | Shortcut | Action selector |
|---|---|---|
| Archive |  | `submenuAction:` |
| Extensions |  | `submenuAction:` |
| Help |  | `submenuAction:` |
| Spaces |  | `submenuAction:` |
| Tabs |  | `submenuAction:` |
| Window |  | `submenuAction:` |
| Arc |  | `submenuAction:` |
| File |  | `submenuAction:` |
| Edit |  | `submenuAction:` |
| View |  | `submenuAction:` |

### Substitutions

| Item | Shortcut | Action selector |
|---|---|---|
| Smart Copy/Paste |  | `toggleSmartInsertDelete:` |
| Text Replacement |  | `toggleAutomaticTextReplacement:` |
| Smart Links |  | `toggleAutomaticLinkDetection:` |
| Smart Quotes |  | `toggleAutomaticQuoteSubstitution:` |
| Smart Dashes |  | `toggleAutomaticDashSubstitution:` |
| Data Detectors |  | `toggleAutomaticDataDetection:` |
| Show Substitutions |  | `orderFrontSubstitutionsPanel:` |

### Font

| Item | Shortcut | Action selector |
|---|---|---|
| Underline | ⌘U | `underline:` |
| Bold | ⌘B | `addFontTrait:` |
| Italic | ⌘I | `addFontTrait:` |

### Speech

| Item | Shortcut | Action selector |
|---|---|---|
| Stop Speaking |  | `stopSpeaking:` |
| Start Speaking |  | `startSpeaking:` |

### Transformations

| Item | Shortcut | Action selector |
|---|---|---|
| Capitalize |  | `capitalizeWord:` |
| Make Lower Case |  | `lowercaseWord:` |
| Make Upper Case |  | `uppercaseWord:` |

### Format

| Item | Shortcut | Action selector |
|---|---|---|
| Font |  | `submenuAction:` |
