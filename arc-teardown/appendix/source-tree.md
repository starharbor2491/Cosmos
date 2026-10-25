# Partial source tree

Swift/ObjC source paths embedded in the main executable (from `#file`/`#fileID` in assertions, logging and `fatalError`), relative to the CI checkout `…/_work/arc/arc/`. Only files that contain such call sites appear, so this is a partial map of the real tree. Third-party checkouts (`Stage/SourcePackages`) are omitted.

509 files. Top level: `Browser/` is the app target; `Frameworks/<Package>/Sources/<Module>/` are local Swift packages.

## Browser/AppleScript (1 files, 1 modules)

- **(app target)**: `AppDelegate+Applescript.swift`

## Browser/Application (22 files, 1 modules)

- **(app target)**: `AppDelegate.swift`, `ApplicationManagers/DebugReducer.swift`, `ApplicationManagers/DeveloperMainMenuProvider.swift`, `ApplicationManagers/GithubParserDebugUIManager.swift`, `MainWindowController.swift`, `Store/AppReducer+SyncedPreferences.swift`, `Store/AppReducer.swift`, `Store/AppState+Appearence.swift`, `Store/AppState+AutoUpdate.swift`, `Store/AppState+DefaultBrowserPrompts.swift`, `Store/AppState+DefaultLinkRoutes.swift`, `Store/AppState+DeveloperMainMenuReducer.swift`, `Store/AppState+LiveCalendars.swift`, `Store/AppState+OnDeterminingFilename.swift`, `Store/AppState+OnUpdateFlag.swift`, `Store/AppState+PerformanceSettings.swift`, `Store/AppState+SearchClientManager.swift`, `Store/AppState+SidebarBanners.swift`, `Store/AppState+SidebarHelpers.swift`, `Store/AppState+Sync.swift`, `Store/AppState+Windows.swift`, `Store/SiteSearchMigrations.swift`

## Browser/CommandBar (1 files, 1 modules)

- **(app target)**: `Placeholder/WindowState+CommandBarPlaceholder.swift`

## Browser/DataStore (1 files, 1 modules)

- **(app target)**: `RestoreSidebarDataFlow.swift`

## Browser/Debugging (1 files, 1 modules)

- **(app target)**: `ViewGeometryDebugging.swift`

## Browser/PictureInPicture (1 files, 1 modules)

- **(app target)**: `PictureInPictureState.swift`

## Browser/Sidebar (11 files, 1 modules)

- **(app target)**: `AppTrayBadgingProvider.swift`, `Previews/AppPreviews.swift`, `Previews/AppState+Previews.swift`, `SidebarCells/ArcDocumentCellState.swift`, `SidebarCells/EaselCellState.swift`, `SidebarCells/SelectableCellView.swift`, `SidebarCells/SharedObjectCellState.swift`, `SidebarCells/SidebarSpaceState+SplitView.swift`, `SidebarCells/TabCellState.swift`, `SidebarCells/TabCellView.swift`, `SidebarCells/WelcomeToArcCellState.swift`

## Browser/WindowContent (7 files, 1 modules)

- **(app target)**: `Modals/ModalV2WindowContentContainerViewController.swift`, `StatusTextView/StatusTextController.swift`, `WebContentViewController.swift`, `Window+WindowContentViewControllerState.swift`, `WindowContentViewController+Menu.swift`, `WindowContentViewController+State.swift`, `WindowContentViewController.swift`

## Browser/Windows (29 files, 1 modules)

- **(app target)**: `BrowserWindow.swift`, `LittleWindowViewController.swift`, `Store/WindowFolderPreview.swift`, `Store/WindowReducer.swift`, `Store/WindowState+AIRenameTabs.swift`, `Store/WindowState+ArcDocument.swift`, `Store/WindowState+Boosts.swift`, `Store/WindowState+Capture.swift`, `Store/WindowState+CommandBarHelpers.swift`, `Store/WindowState+ContentToolbar.swift`, `Store/WindowState+ContextMenu.swift`, `Store/WindowState+CopyQuote.swift`, `Store/WindowState+GoogleMeetAutoPiP.swift`, `Store/WindowState+Home.swift`, `Store/WindowState+InstantLinks.swift`, `Store/WindowState+KeyboardShortcutsEDU.swift`, `Store/WindowState+Library.swift`, `Store/WindowState+Lifecycle.swift`, `Store/WindowState+LittleBrowser.swift`, `Store/WindowState+PasswordImportPrompt.swift`, `Store/WindowState+Pasteboard.swift`, `Store/WindowState+Previews.swift`, `Store/WindowState+SharableArcObjects.swift`, `Store/WindowState+ShareSettingsWindow.swift`, `Store/WindowState+Undo.swift`, `Store/WindowState+WindowLayout.swift`, `Store/WindowsState+Restoration.swift`, `Store/WindowsState.swift`, `WindowViewController.swift`

## Frameworks/ADK (1 files, 1 modules)

- **ADK**: `Browser+Import.swift`

## Frameworks/ARC (303 files, 77 modules)

- **ADKApplicationFeature**: `ADKApplicationFeature.swift`
- **ASE2**: `ConfigurationClient.swift`
- **ActionInspectorDashboard**: `ActionInspectorDataStore+DependencyKey.swift`, `ActionInspectorDataStore+Integration.swift`
- **AdBlocking**: `AdBlocking.swift`, `ManageAdBlockersDialogContext.swift`
- **AppFeature**: `SentryClient+LiveValue.swift`
- **Archive**: `ArchiveState+AutoArchive.swift`, `ArchiveState.swift`
- **AskArc**: `AskArcGeneratedPage.swift`, `AskArcGenerator.swift`, `AskArcStore.swift`, `Views/AskArcViewModel.swift`
- **AskArcComparisonTool**: `UI_macOS/AskArcComparisonToolHelpers.swift`
- **AskInPage**: `AskInPageChat.swift`
- **AuthFeature**: `AuthState/AuthReducer.swift`, `AuthWizard.swift`, `OnboardingAnalytics.swift`, `Setup.swift`, `SignInScreenReducer.swift`, `SignUpScreenReducer.swift`, `WelcomeScreen.swift`
- **BackForwardList**: `BackForwardList.swift`
- **BaseHomeComponents**: `HomePreferencesClient.swift`
- **BoostsDialog**: `BoostsInstallationDialog.swift`, `BoostsSharingDialog.swift`
- **BoostsEditor**: `BoostsEditor.swift`
- **CommandBar**: `CommandBarSelectionOptions.swift`, `Instance/CommandBarInstance.swift`, `Instance/CommandBarIntegrationClient+Implementations.swift`, `Instance/CommandBarIntegrationClient.swift`, `SearchClient.swift`, `Store/CommandBar.swift`, `Store/CommandBarInteractionPerformanceTracker+LiveValue.swift`, `Store/CommandBarInteractionPerformanceTracker.swift`, `Store/CommandBarRemoteConfiguration.swift`, `Store/CommandBarSearchSuggestionsPrivacy.swift`, `Store/SearchEngineClient.swift`, `Suggestions/Suggestion+ViewState.swift`, `UI_macOS/CommandBarContainer.swift`, `UI_macOS/InputContainer/CommandBarInputContainer.swift`, `UI_macOS/Suggestions/SuggestionsView.swift`, `URLInputSearchClient+Live.swift`
- **CommandBarAdditionalRankingDataStoreClient**: `Client.swift`, `CommandBarAdditionalRankingData.swift`
- **ContextMenus**: `SidebarMenu+ListContextMenu.swift`, `SidebarMenu+MoveMenu.swift`, `SidebarMenu+PlatformGeneration.swift`, `SidebarMenu+TabContextMenu.swift`, `SidebarSpaceState+SpaceContextMenu.swift`, `SpaceMenu.swift`, `macOS/SidebarMenu+PlatformSpecificItems.swift`
- **DefaultBrowserPrompts**: `DefaultBrowserPromptReducer.swift`, `StorableDefaultBrowserPromptState+Dependencies.swift`
- **DeleteAccountFeature**: `DeleteAccount.swift`
- **DocumentsFeature**: `Store/ArcDocumentReducer.swift`, `Store/ArcDocumentState+Helpers.swift`
- **DynamicLogLevels**: `DynamicLogLevelsFeature.swift`, `StorableDynamicLogLevels.swift`
- **Easel**: `EaselReducer.swift`, `EaselState.swift`
- **EventSource**: `EventSource.swift`
- **FaviconDominantColorFetcher**: `FaviconDominantColorFetcher.swift`
- **FirebaseSidebarSyncCommon**: `EnableSync+Shared.swift`, `FeatureState+DebugLogs.swift`, `FeatureState+Enable.swift`, `FeatureState+ErrorHandling.swift`, `FeatureState+RemoteUpdate.swift`, `FeatureState+Subscription.swift`, `FeatureState+Upload.swift`, `FeatureState+Wipeout.swift`
- **GeoLocation**: `GeoLocationClient.swift`
- **HomeBadging**: `HomeBadgingClient.swift`, `HomeBadgingFeature.swift`, `HomeBadgingItemsState.swift`, `ItemPreviewPresenter.swift`
- **HomeButton**: `Pages/Archive/ArchiveReducer.swift`, `Pages/Downloads/DownloadsPageReducer.swift`, `Pages/Media/MediaReducer.swift`, `Reducer.swift`
- **HoverCards**: `HoverCardViewModel.swift`
- **ImportFeature**: `AdBlockersSelection/AdBlockersSelection.swift`, `BookmarksSelection/BookmarksSelection.swift`, `ImportFeature.swift`, `ImportProfile/ImportProfile+State.swift`, `ImportProfile/ImportProfile.swift`, `ImportSafariKeychain/UI_macOS/ImportSafariKeychain.swift`
- **ImportMenuFeature**: `ImportDialog.swift`, `ImportMenuReducer.swift`, `PasswordImportPrompt.swift`
- **KeyboardShortcutsEducationFeature**: `UI_macOS/KeyboardShortcutsEDUWindowController.swift`
- **LLM**: `LLMProvider.swift`, `OpenAI/ChatGPT.swift`, `UniversalLLMClient.swift`, `WebPageSnapshot.swift`
- **LibraryData**: `LibraryDataClient.swift`
- **LinkRouting**: `LinkRoutingClient.swift`, `LinkRoutingEditor.swift`
- **LittleBrowser**: `LittleBrowser.swift`
- **LiveCalendars**: `LiveCalendars.swift`
- **LiveFoldersFeature**: `LiveFoldersFeature.swift`, `StorableLiveData.swift`
- **MacLifecycle**: `MacLifecycle.swift`
- **MediaControlsFeature**: `MediaControlsFeature.swift`, `MediaControlsFeatureIntegrator+DependencyKey.swift`, `MiniPlayerFeature.swift`, `MiniPlayerState+Observations.swift`
- **MembershipCard**: `StorableMembershipCardState+Dependencies.swift`
- **MeterMetrics**: `MeterMetrics.swift`
- **PreferencesFeature**: `PreferencesFeature.swift`, `ProfilePreferencesState.swift`
- **Previews**: `Client/PreviewsDataClient.swift`, `Fetchers/GoogleCalendarDataFetcher.swift`, `Fetchers/RecentPagesFetcher.swift`
- **ProcessMemoryUsage**: `ProcessMemoryUsage.swift`
- **ProfilesUI**: `ProfileDialogUtils.swift`
- **RateLimiting**: `RateLimiterClient.swift`
- **ReferralCodeFeature**: `ReferralCode.swift`, `ReferralCodeDialog.swift`
- **Scraping**: `HTMLFetchClient.swift`, `HTMLFetchClientImpl.swift`, `HTMLScrapingRulesProvider.swift`, `URLRateLimiters.swift`, `WebViewHTMLFetcher.swift`
- **SearchClientManager**: `ChromiumCandidatesProvider.swift`, `InstantLinksCandidateProvider.swift`, `SearchNullStateProvider.swift`, `TypeTravelCandidatesProvider.swift`
- **ShareMenu**: `ShareMenu.swift`
- **SharedAppFeature**: `ADKFeatureFlags.swift`, `AdBlockManagementReducer.swift`, `AppData+ADKApplicationFeature.swift`, `AppData+Analytics.swift`, `AppData+AppIcon.swift`, `AppData+ArcMaxAutoOptIn.swift`, `AppData+Auth.swift`, `AppData+CurrentUser.swift`, `AppData+ImportBookmarks.swift`, `AppData+Instrumentation.swift`, `AppData+LiveCalendars.swift`, `AppData+LiveFolders.swift`, `AppData+ManageAdBlockers.swift`, `AppData+OpenURL.swift`, `AppData+Preferences.swift`, `AppData+Profiles.swift`, `AppData+RemoteConfig.swift`, `AppData+SidebarBanner.swift`, `AppData+Sync.swift`, `AppData+Zendesk.swift`, `AppData.swift`, `AppSidebarDataStoreIntegration.swift`, `AppSidebarReducer.swift`, `DeveloperMainMenu.swift`, `DownloadNamingFeatureAction.swift`, `OnboardingConfigurator.swift`, `SharedAnalyticsReducer.swift`, `SharedAppFeature+Sentry.swift`, `SharedAppFeature.swift`, `SharedAuthenticationFeature.swift`, `SharedWriteToDiskFeature.swift`, `SidebarAnalyticsTracker.swift`, `SoftwareUpdates/AppSoftwareUpdate.swift`, `SoftwareUpdates/SoftwareUpdate.swift`, `Tracing/TracingFeatureState.swift`, `WebContentsLifecycle.swift`
- **SharedArchiveFeature**: `SharedArchiveFeature.swift`
- **SharedDownloadsFeature**: `SharedDownloadsFeature.swift`
- **SharedWindowFeature**: `BrowserNavigationButtonsFeature.swift`, `ClosedSidebarItemsCache.swift`, `SharedWindowFeature.swift`, `SidebarSpaceState.swift`, `Undo/ArcUndoManager+Live.swift`, `Undo/UndoManagerProvider.swift`, `Undo/WindowData+RegisterCloseWindowContent.swift`, `Undo/WindowReducer+Undo.swift`, `WebContentNavigation.swift`, `WindowData+ArcDocument.swift`, `WindowData+Archive.swift`, `WindowData+AskInPage.swift`, `WindowData+Audibility.swift`, `WindowData+BackForwardList.swift`, `WindowData+BrowserExtensions.swift`, `WindowData+Cast.swift`, `WindowData+CloseItems.swift`, `WindowData+CloseWindowContent.swift`, `WindowData+CommandBarHelpers.swift`, `WindowData+ContentNavigation.swift`, `WindowData+ContentReparenting.swift`, `WindowData+CreateWindowContent.swift`, `WindowData+Creation.swift`, `WindowData+DevTools.swift`, `WindowData+Dialogs.swift`, `WindowData+Dragging.swift`, `WindowData+Duplication.swift`, `WindowData+EmailPeeking.swift`, `WindowData+Expansion.swift`, `WindowData+Folders.swift`, `WindowData+Fullscreen.swift`, `WindowData+HoverCards.swift`, `WindowData+ItemSelection.swift`, `WindowData+LiveCalendars.swift`, `WindowData+LiveFolders.swift`, `WindowData+MainMenu.swift`, `WindowData+MediaControls.swift`, `WindowData+ModalContent.swift`, `WindowData+ModalHelpers.swift`, `WindowData+ModalItemSwitcher.swift`, `WindowData+MutationHelpers.swift`, `WindowData+Navigation.swift`, `WindowData+Pasteboard.swift`, `WindowData+Profiles.swift`, `WindowData+RenameHints.swift`, `WindowData+Sidebar.swift`, `WindowData+SidebarDebugGeneration.swift`, `WindowData+SidebarItemContextMenus.swift`, `WindowData+SpaceCreationFeature.swift`, `WindowData+SpaceStyleEditor.swift`, `WindowData+Spaces.swift`, `WindowData+SplitViewHelpers.swift`, `WindowData+TabAttributes.swift`, `WindowData+TabCreation.swift`, `WindowData+TabGroups.swift`, `WindowData+Teardown.swift`, `WindowData+TidyTabTitles.swift`, `WindowData+Toasts.swift`, `WindowData+TopApps.swift`, `WindowData+TopBar.swift`, `WindowData+Translate.swift`, `WindowData+WebContentFrame.swift`, `WindowData+WindowContentPresentation.swift`, `WindowInitialAppearanceAction.swift`
- **SharedWindowsFeature**: `SharedWindowsFeature.swift`, `SidebarContainer+Cleanup.swift`, `WindowsCloseContentAction.swift`, `WindowsData+Cleanup.swift`, `WindowsData+Close.swift`, `WindowsData+CloseItems.swift`, `WindowsData+ContentReparenting.swift`, `WindowsData+Creation.swift`, `WindowsData+Dragging.swift`, `WindowsData+LittleBrowser.swift`, `WindowsData+MediaControls.swift`, `WindowsData+Migration.swift`, `WindowsData+MoveItems.swift`, `WindowsData+MoveTabToWindow.swift`, `WindowsData+OpenURL.swift`, `WindowsData+PictureInPicture.swift`, `WindowsData+SplitView.swift`, `WindowsData+TopBar.swift`, `WindowsData+WebContentFrame.swift`
- **SidebarBanner**: `SidebarBanner.swift`
- **SidebarDataStore**: `SidebarDataStore+MutationHelpers.swift`, `SidebarDataStore.swift`
- **SidebarSyncCloudKit**: `EnableSync+Shared/ExportRecoveryPhraseHelpers.swift`, `Extensions/SpaceModel+CloudKit.swift`, `ReopenedSidebarItemsStore.swift`, `SidebarItemDecoder.swift`, `SidebarSync+SyncAction.swift`, `SidebarSync.swift`, `SidebarSyncState+CloudKitUpdate.swift`, `SidebarSyncState+Storable.swift`, `SidebarSyncState+Updates.swift`
- **SiteControlCenter**: `SiteControlCenterFeature.swift`
- **SoftwareUpdaterClient**: `SoftwareUpdaterClient.swift`, `UI_macOS/SoftwareUpdateManager.swift`
- **SoundEffects**: `SoundEffectClient.swift`
- **SpaceStyleEditor**: `SpaceStyleEditorState.swift`
- **StorableArchive**: `StorableArchive.swift`
- **StorableSidebar**: `AppSidebarReducerState+Default.swift`, `DefaultSidebarTabType.swift`, `StorableSidebar+Dependencies.swift`
- **StorableWindows**: `StorableWindows+Dependencies.swift`
- **TabCloseDebugger**: `TabCloseDebugClient.swift`, `TabCloseDebugUIClient.swift`, `UI_macOS/TabCloseDebugView.swift`
- **Toasts**: `ToastController.swift`
- **TracingFeature**: `TracingControllerClient.swift`, `TracingUI.swift`
- **Translation**: `TranslateFeature.swift`
- **TypeTravel**: `Client/CandidateFetcher.swift`, `Client/MainMenuClient.swift`, `Client/TypeTravel.swift`, `Client/WindowData+CreateTypeTravelEffect.swift`
- **URLInputter**: `FaviconProvider.swift`, `URLInputSearchClient.swift`, `URLInputterReducer.swift`
- **WebContent**: `WebContentFeature.swift`, `WebContentState+Boosts.swift`, `WebContentState+DeveloperTab.swift`, `WebContentState+Lifecycle.swift`, `WebContentState+PictureInPicture.swift`
- **WebContentBehaviorConfigurationClient**: `WebContentBehaviorConfiguration.swift`
- **WebSearch**: `WebSearchClient.swift`, `WebSearchClientImpl.swift`, `WebSearchWithFallback.swift`
- **WelcomeToArcFeature**: `WelcomeToArc.swift`
- **WindowContents**: `Presentation/WindowContentPresentationMutationContext+SplitView.swift`, `SplitView/ContentToolbarInteractionTracker.swift`, `SplitView/SplitViewLayoutCache.swift`, `WindowContentReducer.swift`, `WindowContentState+FindInPage.swift`, `WindowContentState+Lifecycle.swift`, `WindowContentsReducer.swift`

## Frameworks/ARCClients (125 files, 75 modules)

- **ADKClient**: `ADKClient+Dependencies.swift`, `DownloadManager.swift`, `WebContentFrame.swift`
- **ADKClientLive**: `ADKClient+Live.swift`
- **AlertClient**: `AlertClient.swift`
- **AnalyticsClient**: `AnalyticsClient+Dependencies.swift`, `AnalyticsClient+LiveValue.swift`, `ContextPlugin.swift`
- **AppEnvironment**: `AppEnvironment+Dependency.swift`, `BCNYApplication+Dependency.swift`
- **AppIconClient**: `AppIconClient.swift`, `UI_macOS/AppIconApplier.swift`
- **AppInfo**: `AppInfo.swift`
- **AppLaunchInteractionTrackerClient**: `AppLaunchInteractionTrackerClient.swift`
- **AppRestartClient**: `AppRestartClient.swift`
- **ApplicationPaths**: `ApplicationPaths.swift`
- **ApplicationReportClient**: `ApplicationReportClient.swift`
- **ArchiveDataStoreClient**: `ArchiveDataStoreClient.swift`, `ArchiveSnapshotCacheClient+LiveValue.swift`
- **BaseModels**: `AuthSession.swift`, `LiveItems/LiveCalendar.swift`, `LiveItems/LiveItemModels.swift`, `NoteDocumentType.swift`, `Sidebar/SidebarContainer+Cleanup.swift`, `Sidebar/SidebarData+Spaces.swift`, `Sidebar/SidebarState+AncestryHelpers.swift`
- **BlockListClient**: `BlockListClient.swift`, `BlockListConfiguration.swift`
- **BoostsClient**: `BoostsClient.swift`, `BoostsStorageFirebaseImpl.swift`, `StorableBoostsDataStore.swift`, `UI_macOS/BoostFaviconView.swift`
- **BugReporterClient**: `BugReporterClient.swift`
- **CaptureClient**: `CaptureClient.swift`
- **CloudKitContainerClient**: `CloudKitContainerClient.swift`, `SyncEngine/SyncEngine.swift`
- **ContentPlaceholderClient**: `ContentPlaceholderClient.swift`, `ContentPlaceholderClientImpl.swift`
- **ContentSnapshotClient**: `ContentSnapshotClient.swift`
- **DefaultBrowserClient**: `DefaultBrowserClient.swift`
- **DeveloperModeClient**: `DeveloperModeClient+Dependencies.swift`
- **DialogsClient**: `DialogsClient+Live.swift`, `DialogsClient.swift`
- **DocumentsClient**: `DocumentsClient.swift`
- **DocumentsLibraryClient**: `DocumentsLibraryClient.swift`
- **EaselClient**: `EaselClient.swift`
- **EaselLibraryClient**: `EaselLibraryClient.swift`
- **EncryptionClient**: `EncryptionClient+RecoveryPhrase.swift`, `EncryptionClient.swift`
- **EncryptionRecoveryClient**: `EncryptionRecoveryClient.swift`
- **FeatureFlags**: `FeatureFlagsClient+Dependencies.swift`
- **FileManagerClient**: `Mock.swift`
- **FileQueryClient**: `FileQueryClient.swift`
- **FileUploaderClient**: `FileUploaderClient+LiveValue.swift`
- **FirebaseClient**: `FirebaseClient+Cleanup.swift`, `FirebaseClient+Live.swift`, `FirebaseClient+Noop.swift`
- **FirebaseSidebarSyncClient**: `DocumentChangeHelpers.swift`, `EncryptedEntity+FirebaseData.swift`, `FirebaseSidebarSyncClient+Impl.swift`, `FirebaseSidebarSyncClient.swift`, `PublishTransaction.swift`, `TimeThrottlingRebatcher.swift`
- **FirebaseSidebarSyncSchemaClient**: `FirebaseSidebarSyncSchema.swift`
- **FirebaseSyncDebugClient**: `FirebaseSyncDebugClient+Impl.swift`, `FirebaseSyncDebugClient.swift`
- **FirebaseSyncRemoteEncryptionClient**: `FirebaseSyncRemoteEncryptionClient+Impl.swift`, `FirebaseSyncRemoteEncryptionClient.swift`, `MatchEncryptionKeysTransaction.swift`
- **FontsManager**: `FontManagerClient.swift`
- **GitHubClient**: `GitHubClient+PullRequestsParsing.swift`, `GitHubClient.swift`
- **GlobalHotkeyListenerClient**: `GlobalHotkeyManager+Dependencies.swift`
- **HTMLClient**: `HTMLClient.swift`
- **HistogramTrackingClient**: `HistogramTrackingClient.swift`, `LoggingHistogramClient.swift`
- **ImageCache**: `FaviconCacheClient+LiveValue.swift`
- **ImageURLLoaderClient**: `ImageURLLoaderClient.swift`
- **InteractionInstrumentationClient**: `InteractionInstrumentationClient+Live.swift`
- **KeyBindings**: `KeyBindingsClient+Noop.swift`, `KeyBindingsClient.swift`, `StorableKeyBindings.swift`
- **KeychainClient**: `KeychainClient.swift`
- **LiveCalendarClient**: `LiveCalendarClient.swift`
- **LiveNotionClient**: `LiveNotionClient+FetchBlocks.swift`, `LiveNotionClient+FetchRecords.swift`, `LiveNotionClient+PageChunk.swift`, `LiveNotionClient+PageVisitors.swift`, `LiveNotionClient+QueryCollection.swift`, `LiveNotionClient.swift`
- **LiveSlackClient**: `LiveSlackClient.swift`, `SlackLocalConfigClient.swift`
- **MachineID**: `MachineID.swift`
- **MainThreadChecker**: `MainThreadChecker.swift`
- **MediaControlsDataStore**: `MediaControlsDataStore+DependencyKey.swift`
- **MeterClient**: `MeterClient.swift`
- **NewWindowPerfClient**: `NewWindowPerfClient.swift`
- **OpenURLClient**: `Mocks.swift`
- **PasteboardClient**: `PasteboardClient+Dependencies.swift`
- **ProcessCollectorClients**: `ProcessAgeCollectorClient.swift`, `ProcessMemoryCollectorClient_macOS.swift`
- **ReferralCodeClient**: `ReferralCodeClient.swift`
- **SessionRestorationClient**: `SessionRestorationClient.swift`
- **SharableArcObjectsClient**: `SharableArcObjectsClient.swift`
- **SharingServiceClient**: `SharingServiceClient.swift`
- **SyncedPreferencesClient**: `SyncedPreferencesClient.swift`
- **TLDClient**: `TLDClient.swift`
- **TabSwitchingPerfTracker**: `TabSwitchingPerfTracker.swift`
- **TelemetryClient**: `InputInteractionDiagnosticsClient.swift`, `SentryClient+Impl.swift`, `TelemetryClient.swift`, `TracingClient.swift`, `tracingBackends/macOS/DataDogUtility.swift`
- **TopBarColorClient**: `TopBarColorClient.swift`
- **URLClientBase**: `BearerTokenProvider.swift`, `URLLoaderClient.swift`
- **UserDefaultsClient**: `Mocks.swift`
- **UserNotificationsClient**: `Mock.swift`, `macOS/Live.swift`
- **UtilityQueue**: `UtilityQueue.swift`
- **WebpageLoadingPerfClient**: `WebpageLoadingPerfClient+Dependencies.swift`, `WebpageLoadingPerfClient.swift`
- **WindowProvider**: `WindowProvider.swift`
- **WorkspaceClient**: `WorkspaceClient+Live_macOS.swift`, `WorkspaceClient.swift`

## Frameworks/ARCFoundation (5 files, 2 modules)

- **ARCFoundation**: `ComposableArchitecture/ComposableArchitectureShims.swift`, `ComposableArchitecture/TestStore+strictFinish.swift`
- **ARCFoundationBase**: `Dependencies/DependencyBox.swift`, `Dependencies/DependencyPlaceholder.swift`, `Dependencies/DependencyPlaceholderBox.swift`

## Frameworks/ARCUI (1 files, 1 modules)

- **ARCUI**: `UI_macOS/StackingView.swift`

