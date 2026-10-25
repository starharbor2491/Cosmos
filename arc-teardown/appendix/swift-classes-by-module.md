# Swift classes by module

Objective-C-visible Swift class names recovered from `_TtC…` runtime names in the arm64 slice of `Contents/MacOS/Arc` (Arc 1.170.0), demangled with `swift-demangle`. Private-discriminator suffixes are stripped. Structs, enums and non-`@objc` types are not visible this way, so this is a lower bound.

## Arc modules (168)

### ARCUI (158)

`AnimatedEllipsisView`, `AnimatedGrainViewImpl`, `AnimatedLogoView`, `AnimatedOrbViewImpl`, `AnimatedVideoView`, `ArcDraggingController`, `ArcDraggingSessionImpl`, `ArcDraggingWindow`, `ArcOnDragRepresentable.DraggableView`, `BackgroundAccessibleView`, `BackgroundColorView`, `BackgroundVideoViewImpl`, `BorderPulseLayer`, `BorderedScrollViewCoordinator`, `BorderlessTextField`, `BrightnessPalette`, `CAAnimationSharedDelegate`, `CALayerAnimationsDisablingDelegate`, `CallbackMenuItem`, `CircularProgressView`, `ClickableTextView`, `ConfettiConfig`, `CoreUIImageWorkSerializer`, `CountdownTextField`, `CursorModifierView`, `CustomInsetSearchField`, `CustomPopoverBackgroundView`, `CustomPopoverRootView`, `CustomSecureTextField`, `CustomSelectionColorTextField`, `CustomTextField`, `DecorationView`, `DimmedOverlayButton`, `DisclosureView`, `DisplayLinkProvider`, `DragCoordinator`, `DragEventCollectionView`, `DraggingDestinationForwardingView`, `DropdownSelectorFieldView`, `DropdownSelectorOptionView`, `DropdownSelectorPanel`, `DropdownSelectorPanelContentView`, `DropdownSelectorSearchField`, `EdgeFeedbackView`, `FacepileView`, `FeatheredTransitioningLabel`, `FeatheredTruncatingLabel`, `FirstResponderAcceptingView`, `FirstResponderOnClickTextView`, `FlipTransitionView`, `FlippedClipView`, `FlippedView`, `FocusRingSettableTextField.Coordinator`, `ForwardingScrollView`, `GradientView`, `HStacking`, `HoverRegionTracker`, `HoverableButton`, `HoverableButtonAdjustingContentTint`, `HoverableControl`, `HoverablePopUpButton`, `HoverableView`, `IconWithProgressIndicatorView`, `IdleFloatingView`, `ImageAspectView`, `ImageCustomFillView`, `ImageHorizontallyStretchableView`, `ImageStretchableChinView`, `InvisibleScroller`, `LayerAnimationCopyingDelegate`, `LayerAnimationCopyingDelegate.AnimationAction`, `LayerBackedView`, `LayerConfiguration`, `LayeredImageCache`, `LoopingPlayerView.LoopingPlayerViewImpl`, `MMCQ`, `MMCQ.ColorMap`, `MMCQ.VBox`, `ManualKeyboardFocusLoopCoordinator`, `MarqueeText.ViewModel`, `MaskedTextField`, `MenuSearchField`, `MinimumPanGestureRecognizer`, `ModifierFlagsObserver`, `MouseDownModifier.Representable.Coordinator`, `MouseDownModifier.Representable.CoordinatorView`, `MouseInsideModifier.Representable.Coordinator`, `MouseListener`, `MouseMoveModifier.Representable.Coordinator`, `MovableWindow`, `MovableWindowContentView`, `MovableWindowController`, `MovableWindowHostLayer`, `MovableWindowState`, `NSEventLocalMonitor`, `NSTextViewRepresentable.Coordinator`, `NSViewAccessor`, `NoHitTestTextField`, `NoHitTestView`, `NoInsetTextField`, `NoInsetTextField.FieldCell`, `NoScrollWKWebView`, `NonClippingView`, `OverrideFontTextField`, `OverrideFontTextFieldCell`, `ParticleNSView`, `PassthroughView`, `PopoverBackgroundView`, `PrimaryActionButton`, `ProxyKeyWindow`, `RadialProgressItemView`, `RecordingDotIndicatorAppKit`, `RightClickAwareView`, `ScrimLoadingIndicatorRepresentable.Coordinator`, `ScrimLoadingIndicatorView`, `ScrimLoadingIndicatorView.ViewModel`, `ScrollInteraction`, `ScrollListener`, `ScrollRecognizer`, `ScrollWheelObserver`, `ShadowPathAction`, `ShadowView`, `SidebarCellButtonCloseContentView`, `SidebarCellButtonSystemImageContentView`, `SlashView`, `Spacing`, `SparklesOverlayView`, `SparklingIconView`, `SplitViewContentPaneView`, `SplitViewController`, `SplitViewControllerDefaultDraggerHandleView`, `StackingView`, `StatefulButton`, `StreamingTextView`, `TaggableView`, `TextFieldRepresentable.Coordinator`, `TextViewWithPlaceholder`, `ThumbnailProvider`, `TintableImageLayer`, `TouchTransparentView`, `TransitioningTextOverlayView`, `TranslucentButton`, `UnconstrainedNSWindow`, `UnmaskedView`, `UnreadPipView`, `VStacking`, `VelocityTracker`, `VerticallyCenteredTextFieldCell`, `ViewHoverTracker`, `ViewMenuKeyboardSelectionHandler`, `WebKitView.Coordinator`, `WindowContentGrabber`, `WindowDraggableView`, `WindowExpansionAnimator`, `WindowStandardButtons`, `_AlternateClickView`, `_AnimatedSmileyView`, `_ControlButton`

### Arc (156)

`AnimatedFlowerView`, `AnimatedGradientView`, `AppDelegate`, `AppTrayBadgingProvider`, `ArcDocumentCellView`, `ArcDocumentPIPWindowControllerViewModel`, `ArcPIPWindowControllerViewModel`, `ArcTopBarColorObserver`, `AskInPageHostingView`, `BackgroundTabAffordanceController`, `BannerView.State`, `BrowserApp`, `BrowserExtensionWindow`, `BrowserExtensionWindowController`, `BrowserExtensionsMainMenuProvider`, `BrowserExtensionsView`, `BrowserNavigationButtons`, `BrowserWindow`, `ChevronView`, `CommandBarIconView`, `CommandBarPlaceholderButtonsView`, `CommandBarPlaceholderStatusButton`, `CommandBarPlaceholderTextMaskView`, `CommandBarPlaceholderTextView`, `CommandBarPlaceholderView`, `CommandFTextField`, `CopyLinkViewModel`, `CustomInfoPickerHostingView`, `DefaultBrowserPromptUIManager`, `DevToolsManager`, `DevToolsWindowController`, `DeveloperMainMenuProvider`, `EaselCellView`, `EditableTextFieldWithCompletionHandler`, `FindInPageView`, `FloatingSidebarBackgroundView`, `FlowerIconView`, `FolderPreviewHostView`, `GenericEaselWebContentProvider`, `GitHubParserDebugUIManager`, `GitHubParserDebugWindowController`, `HoverHint`, `IconView`, `InstantLinksCellView`, `ListHeaderCellView`, `LittleBrowserWindow`, `LittleWindowViewController`, `MainMenuManager`, `MainMenuOutlets`, `MainWindowController`, `MainWindowsManager`, `ModalV2SidebarBadgeView`, `ModalV2WindowContentContainerViewController`, `NewTabCellView`, `PasteboardItemWithFile`, `PinnedTabSectionEduBanner`, `PinnedTabSectionEduBannerTableRowView`, `PreviewBackgroundView`, `PreviewView`, `ResizeRegionIndicatorLayer`, `RestoreDataViewController`, `RestoreDataWindowController`, `RestoreSidebarDataFlow`, `SectionHeaderHoverableButton`, `SelectedTextController`, `SharedObjectCellView`, `SidebarCellImageContainerView`, `SidebarClearButton`, `SidebarCollectionViewTransitionLayout`, `SidebarDragRegionWindow`, `SidebarHeaderView`, `SidebarItemUnreadBadgeView`, `SidebarMenuControllerMac`, `SidebarPagingContainerAppTrayCollectionViewItem`, `SidebarPagingContainerCollectionViewLayout`, `SidebarPagingContainerCollectionViewLayout.InvalidationContext`, `SidebarPagingContainerScrollView`, `SidebarPagingContainerScrollView.ClipView`, `SidebarPagingContainerViewController`, `SidebarPreviewHoverTracker`, `SidebarResizeRegionView`, `SidebarSectionHeaderView`, `SidebarSectionHeaderView.IconView`, `SidebarSpaceViewController`, `SidebarTableRowView`, `SidebarTidyButton`, `SidebarView`, `SidebarViewController`, `SolidColorView`, `SpaceControlsView`, `SpaceCreationHostingViewController`, `SpaceManagementAddSpaceView`, `SpaceManagementAddSpaceViewCollectionViewItem`, `SpaceManagementCollectionViewItem`, `SpaceManagementCollectionViewLayout`, `SpaceManagementDrggerView`, `SpaceManagementHScrollCollectionViewItem`, `SpaceManagementHScrollCollectionViewItem.ScrollView`, `SpaceManagementView`, `SpaceManagementViewControllerSpacesPage`, `SpacesMainMenuProvider`, `SpacesPage.Configuration`, `SparksView`, `SplitDragPreviewView`, `SplitViewBottomDraggerHandleView`, `SplitViewCellChildItemView`, `SplitViewCellChildrenContainerView`, `SplitViewCellCustomInfoView`, `SplitViewCellItemCountIconView`, `SplitViewCellView`, `SplitViewContentPlaceholderView`, `SplitViewContentPlaceholderView.BorderView`, `SplitViewDraggerHandleView`, `SquiggleViewModel`, `StatusTextController`, `TabCellRegionalBackgroundButton`, `TabCellView`, `TabGroupHeaderCellView`, `TablistEdgeDragController`, `TablistOutlineDelegate`, `TablistOutlineView`, `TablistOverflowIndicatorView.ViewState`, `TablistView`, `TablistView.OverflowIndicator`, `TablistViewController`, `TextFieldContainer`, `TidyTabsButtonImageView`, `TopBarPanelContainerView`, `TopBarPanelViewModel`, `UnpinnedSectionDividerCellView`, `UnpinnedSectionHeaderCellView`, `ViewGeometryDebugger`, `ViewModel`, `ViewWithScrimInset`, `WebContentPlaceholderView`, `WebContentViewController`, `WebContentViewController.WebContentHostingView`, `WebContentViewController.WebContentHostingView.ConstraintSet`, `WebContentViewControllerSplitView`, `WebContentsLifecycleDebugUIManager`, `WebContentsLifecycleDebugViewController`, `WelcomeToArcCellView`, `WindowAnimationController`, `WindowContentPlaceholderViewController`, `WindowContentViewController`, `WindowContentViewController.ContentView`, `WindowContentViewController.TopBarPanelComponents`, `WindowContentViewControllerDebugView.ViewModel`, `WindowContentsContainerViewController`, `WindowControlButton`, `WindowHoverTracker`, `WindowLayoutController`, `WindowMenuProvider`, `WindowPopoverBackdropView`, `WindowStoreLifetimeTracker`, `WindowViewController`

### EaselUI (87)

`AnchorGuide`, `ArrowControlPoint`, `AspectFillView`, `AspectRatioControlPoints`, `BrowserDataWriter`, `CanvasGrabber`, `CanvasInputOverlay`, `CanvasView`, `CenteringClipView`, `CenteringScrollView`, `ColorPicker`, `ColorPickerView`, `ControlPoint`, `CustomizableCursorButton`, `DragHandle`, `DragSession`, `DynamicTextView`, `EaselAppSession`, `EaselCanvasMenuProvider`, `EaselCanvasViewController`, `EaselContentView`, `EaselCursorCache`, `EaselEditManager`, `EaselEditState`, `EaselEditorViewController`, `EaselImageView`, `EaselImageViewController`, `EaselImageWriter`, `EaselInputPreferences`, `EaselInternalContentView`, `EaselLinkView`, `EaselLinkViewController`, `EaselLiveCaptureOverlay`, `EaselLoadableImageView`, `EaselMessageContentView`, `EaselMessageViewController`, `EaselObjectControllerRegistry`, `EaselObjectMenuProvider`, `EaselObjectPasteboardReader`, `EaselObjectPasteboardWriter`, `EaselObjectViewController`, `EaselRichTextView`, `EaselRichTextViewController`, `EaselShapeView`, `EaselShapeViewController`, `EaselTextView`, `EaselTextViewController`, `EaselTextWriter`, `EaselViewController`, `EaselViewControllerView`, `EaselWebBrowserView`, `EaselWebBrowserViewController`, `EaselWebCardView`, `EaselWebCardViewController`, `EaselWebContentPool`, `EasyButton`, `ExtendedDragArea`, `FakeEaselDataProvider`, `FakeEaselImageLoader`, `FixedScaleView`, `FocusableTextField.Coordinator`, `FontMetrics`, `FrameControlPoint`, `InMemoryEaselDataProvider`, `InMemoryEaselImageLoader`, `InMemoryEaselViewController`, `InputPickerState`, `LinkDataWriter`, `MetaTagParser`, `ModalImageEditor`, `ModalImageEditorContentViewController`, `ModalImageEditorContentViewController.Backdrop`, `ModalImageEditorContentViewController.ModalContainer`, `MoveManager`, `ObjectEditSession`, `ObjectEditor`, `ObjectGroup`, `ObjectView`, `PresenceCursorLayer`, `RichTextDataWriter`, `SearchBar`, `SearchPopover`, `TextLayout`, `TextMenu`, `TextMenuView`, `URLInputView`, `ZoomInteraction`

### CommandBar (30)

`ColorizedIconContainerView`, `CommandBarContainer`, `CommandBarDebugUIManager`, `CommandBarDebugView`, `CommandBarDebugWindowController`, `CommandBarInputContainer`, `CommandBarInputScopedSearchPillView`, `CommandBarSuggestionRowView`, `CommandBarTextField`, `CommandBarView`, `CommandBarViewStateInstance`, `DefaultBrowserPromptView`, `DefaultBrowserPromptView.ViewModel`, `DefaultSuggestionIconContainerView`, `DefaultSuggestionTitleView`, `DefaultSuggestionView`, `IconStackViewModel`, `KeyboardShortcutView`, `SearchSuggestionsPrivacyView`, `SearchSuggestionsPrivacyView.ViewState`, `StandardCommandBarInstance`, `SuggestionArrowAndLabelView`, `SuggestionArrowView`, `SuggestionDebugView`, `SuggestionInstantLinksView`, `SuggestionPillView`, `SuggestionsView`, `TypeLetterInCommandBarStateMachine`, `TypeTravelSuggestionTableViewCell`, `TypeTravelSuggestionView`

### ADK (28)

`ADKApplication`, `ADKApplicationDelegateBridge`, `ADKBrowserDelegate`, `AccessibilityObserver`, `BrowserContextDelegateBridge`, `BrowserContextDevToolsChromium`, `BrowserContextDownloadDelegateBridge`, `BrowserContextHistoryDelegateBridge`, `ChromiumBrowser`, `ChromiumDownload`, `CommandShim`, `CrashKeysObserverBridge`, `DevTools.ProtocolConnection`, `DevTools.Subscription`, `DownloadFeatures`, `EventShim`, `HistogramSamplesDelegateBridge`, `ImportDelegate`, `ImporterProfile`, `ImportingController`, `PerformanceObserverBridge`, `SessionRestorationBrowserDelegate`, `StubWebContent`, `TablessWebContentsUIDelegate`, `TracingControllerChromium`, `WebContentChromium`, `WebContentFeatures`, `WebContentPIPState`

### AppTray (21)

`AppTrayChildItemView`, `AppTrayChildItemView.ViewModel`, `AppTrayCollectionViewLayout`, `AppTrayEmptyStateView`, `AppTrayItemBackgroundView`, `AppTrayItemBadgeView`, `AppTrayItemHighlightRingView`, `AppTrayItemSelectionOutlineView`, `AppTrayItemSubtitleView`, `AppTrayItemViewAppKit`, `AppTrayItemViewCollectionViewItem`, `AppTrayItemViewIconProvider`, `AppTrayItemWrapperView`, `AppTrayView`, `AppTrayViewController`, `AppTrayVisualEffectImageProvider`, `EmptyStateViewModel`, `LiveItemCollectionViewItem`, `LiveItemViewModel`, `PinnedExtensionCollectionViewItem`, `PinnedExtensionCollectionViewItemView`

### ARCFoundationBase (15)

`AsyncLock`, `DeallocTracker`, `Debouncer`, `DefaultFileCacheStorage`, `DependencyPlaceholderBox`, `FileCache`, `FileLogHandler.StreamsManager`, `LazyURL.Storage`, `LongestPrefixFinder`, `ModuleBundle`, `NotificationToken`, `SerialTaskQueue`, `TaskCancellable`, `TimeManipulator`, `WaitableEvent`

### PictureInPicture (14)

`AVPlaybackController`, `Controls.ViewModel`, `DocumentPiPState`, `DocumentPiPTopBarView.ViewModel`, `DocumentPiPWindowContent`, `DocumentPiPWindowController`, `MeetingControls.ViewModel`, `ObservablePlayer`, `PIPOverlayHostView`, `PIPPlaybackController`, `PIPWindowContent`, `PIPWindowController`, `PlayControls.ViewModel`, `TopBarHostingView`

### AuthFeature (13)

`AnimatedGrainViewImpl`, `AnimatedOrbViewImpl`, `AnimatedVideoView`, `AuthViewTextField.FocusLoopKey`, `BackgroundVideoViewImpl`, `FullscreenOverlay`, `SpaceStyleEditorBackgroundView.MouseDownView`, `SwiftUIWKWebView.Coordinator`, `UnboxingManager`, `UnboxingViewController`, `UnboxingWindow`, `UnboxingWindowController`, `WebViewModel`

### HomeButton (13)

`ArchivePage.Configuration`, `BoostsPage.Boost`, `BoostsPage.Configuration`, `DownloadsPage.Configuration`, `DownloadsPagePreviewPresenter`, `EaselsAndNotesPage.Configuration`, `HomePageRegistry`, `HomeViewBridge`, `HomeViewController`, `MediaPage.Configuration`, `MediaPagePreviewPresenter`, `WindowPageRegistry`, `_AnimatedPageSidebarItemView`

### Meter (13)

`CPUExceptionDiagnostic`, `CPUExceptionMetaData`, `CallStack`, `CallStackTree`, `CrashDiagnostic`, `CrashMetaData`, `DiagnosticPayload`, `DiskWriteExceptionDiagnostic`, `DiskWriteExceptionMetaData`, `DlfcnSymbolicator`, `HangDiagnostic`, `HangMetaData`, `MeterPayloadManager`

### TelemetryClient (11)

`Accumulators`, `ActiveBreadcrumbCollector`, `ActiveTraceLogger`, `DataDogTracingBackend`, `DataDogUtility`, `SentryClient.Implementation`, `SentryViewHierarchyDataHandlerImpl`, `SignpostTracingBackend`, `StopWatch`, `TraceBreadcrumbHandler`, `TracingBackendManager`

### ArcMenu (10)

`ArcMenu`, `ArcMenuBackgroundView`, `ArcMenuContentView`, `ArcMenuContentViewController`, `ArcMenuItemView`, `ArcMenuSeparator`, `ArcMenuTextView`, `ArcMenuToggleAccessoryView`, `ArcMenuToggleAccessoryView.ViewModel`, `ArcMenuWindow`

### BoostsClient (10)

`BoostFaviconLoader`, `BoostFaviconResolver`, `BoostsClientImpl`, `BoostsFirebaseRefs`, `BoostsImageCacheImpl`, `BoostsImageCacheImpl.PendingStore`, `BoostsObserver`, `BoostsStorageFirebaseImpl`, `BoostsStorageMemoryImpl`, `BoostsWebContentHelperImpl`

### SoftwareUpdaterClient (9)

`CustomUserDriver`, `DowngradableVersionComparison`, `ReleaseNotesView`, `SoftwareUpdateManager`, `SparkleVersionComparison`, `UpdaterStatusController`, `UpdaterStatusView`, `UpdaterWindowController`, `UpdaterWindowView`

### Capture (8)

`CapturedImageActionsView`, `CapturedImageView`, `ContentCaptureOverlayView`, `ContentCaptureRootView`, `ContentCaptureView`, `ContentCaptureViewController`, `DimmedBackgroundView`, `FocusRectAnimator`

### PreferencesFeature (8)

`AdvancedPreferencesLocalState`, `AvatarLoader`, `ErrorAnimationModifier.AnimationDriver`, `GeneralPreferencesLocalState`, `KeyboardShortcutInputView`, `NSButtonRepresentable.Coordinator`, `ProfilePreferencesLocalState`, `TermsOfServiceLocalState`

### ArcTooltip (7)

`ArcTooltipModifier.ConditionalHitTestView`, `NSViewArcTooltipTrackingEventCoordinator`, `PresentationTraits`, `TooltipController`, `TooltipView`, `TooltipWindow`, `TooltipWindowController`

### BoostsEditor (7)

`BoostsEditorOverlayController`, `BoostsEditorOverlayView.WebContentsAdaptor`, `BoostsEditorShelfController`, `BoostsEditorWindowContent`, `BoostsEditorWindowController`, `HandleGesturesMarkerView`, `HoveredElementTracker`

### ContentPanel (7)

`ContentPanelContainerView`, `ContentPanelSpringManager`, `ContentPanelTextField`, `ContentPanelTextView`, `ContentPanelViewModel`, `VerticallyAlignedTextFieldCell`, `WindowScreenshotViewModel`

### CustomInfoPicker (7)

`EmojiCollectionItemView`, `EmojiCollectionViewItem`, `EmojiGridCollection`, `EmojiSkinTonePicker`, `EmojiSkinTonePickerViewController`, `EmojiStackView`, `NSImageViewAcceptingFirstMouse`

### ModalContent (7)

`ModalControlState`, `ModalV2HostView`, `ModalV2HostViewController`, `ModalWindow`, `ModalWindowContentViewController`, `ModalWindowController`, `ModalWindowLayoutController`

### ProfilesUI (7)

`ChangeProfileDialogContext`, `CreateProfileDialogContext`, `ProfileChangeSheetWindow`, `ProfileCreationSheetWindow`, `ProfileIndicatorHostingView`, `ProfileIndicatorViewState`, `SpaceSelectionState`

### AskArc (6)

`AskArcLoadingIndicatorViewModel`, `AskArcPersistentCacheImpl`, `AskArcSessionImpl`, `AskArcStore`, `AskArcViewModel`, `CountingTimer`

### DocumentsFeature (6)

`ArcDocumentEditorViewController`, `ArcDocumentErrorContent`, `ArcDocumentErrorView`, `ArcDocumentErrorViewController`, `ArcDocumentLoadingView`, `ArcDocumentLoadingViewController`

### EaselClient (6)

`EaselFirebaseDataProvider`, `EaselFirebasePresencePinger`, `EaselFirebaseRefs`, `EaselManagerImpl`, `EaselObjectFirebaseRequestHandler`, `EaselRemoteImageLoader`

### HoverCards (6)

`HoverCardPopover`, `HoverCardProgressView`, `HoverCardViewController`, `HoverCardViewModel`, `HoverCardWindow`, `HoverCardsController`

### LLM (6)

`MockChatGPTClient`, `MockClaudeClient`, `MockLLMClient`, `MockUniversalClient`, `UniversalClient.MessageAccumulatorBox`, `UniversalClient.TokenUsageBox`

### LittleBrowser (6)

`LittleBrowserDownloadsTrayItemView`, `LittleBrowserDownloadsTrayViewController`, `LittleBrowserMoveMenuWindow`, `LittleBrowserMoveMenuWindowController`, `LittleBrowserNUXView`, `PassthroughView`

### LiveSlackClient (6)

`LiveSlackClientImpl`, `PayloadBuilder`, `SlackLocalConfigCache`, `SlackLocalConfigCache.Entry`, `SlackLocalConfigJSON.Cache`, `SlackLocalConfigJSON.Snapshot`

### SearchClientManager (6)

`DocumentsCandidateProvider`, `EaselCandidatesProvider`, `SearchClientManager`, `SidebarCandidatesProvider`, `TopDomainsCandidatesProvider`, `TypeTravelCandidatesProvider`

### SidebarDock (6)

`SidebarDockCollectionViewItem`, `SidebarDockCollectionViewLayout`, `SidebarDockItemLayoutAttributes`, `SidebarDockItemView`, `SidebarDockView`, `SidebarPlusButtonGradientBackgroundViewView`

### WindowBackground (6)

`WindowActiveStateTracker`, `WindowBackgroundContainerView`, `WindowBackgroundTranslucencyViewAppKit`, `WindowBackgroundViewExperimental`, `WindowBackgroundViewLegacy`, `WindowBackgroundViewModel`

### WindowThemeUI (6)

`RenderObjects`, `WindowThemeBackgroundMetalRenderer`, `WindowThemeBackgroundViewMetal`, `WindowThemeBackgroundViewMetal.ConfigurationQueue`, `WindowThemeBackgroundViewMetalDebugView`, `WindowThemeBackgroundViewMetalDebugView.ViewModel`

### ADKClient (5)

`ADKTracingBackend`, `ContextDownloadManager`, `StubBrowser`, `StubBrowserContext`, `WebContentFrame`

### ArcRichTextEditor (5)

`ArcRichTextEditorContainerView`, `ArcRichTextEditorView`, `BaseEditorTextView`, `TextEditorFormatMenu`, `TextEditorImageAttachmentCell`

### BoostsDialog (5)

`BoostsCopyLinkAnimationPlayer`, `BoostsDialogSheetWindow`, `CustomNSTextField`, `CustomNSTextFieldRepresentable.TextFormatter`, `DialogViewModel`

### Dialogs (5)

`DialogInfo`, `RadioDialogContext`, `SharedCollectionPromptViewDialog`, `SheetWindow`, `TextInputDialogContext`

### FirebaseSharedSwift (5)

`FirebaseDataDecoder`, `FirebaseDataEncoder`, `__JSONDecoder`, `__JSONEncoder`, `__JSONReferencingEncoder`

### HomeBadging (5)

`HomeBadgingClientImpl`, `HomeButton`, `HomeButtonHoverRegionTracker`, `ItemPreviewPresenter`, `LayoutSpec`

### KeyBindings (5)

`KeyBindingMenuManager`, `KeyBindingsClientImplementation`, `KeyDownView`, `KeyboardShortcutInterceptionView`, `KeyboardShortcutTracker`

### MediaControlsFeature (5)

`MediaControlsFeatureController`, `MediaControlsFeatureIntegratorImpl`, `MediaControlsHostingView`, `StubMediaControlsFeatureIntegrator`, `Wrapper`

### Scraping (5)

`ADKWebViewWrapper`, `HTMLFetchClientImpl`, `HTMLScrapingRulesProviderImpl`, `WKWebViewWrapper`, `WebViewHTMLFetcher`

### Settings (5)

`SegmentedControlStyleViewController`, `SettingsTabViewController`, `SettingsWindowController`, `ToolbarItemStyleViewController`, `UserInteractionPausableWindow`

### ADKClientLive (4)

`ADKClientLive`, `BrowserExtensionsLifeCycleManager`, `BrowserExtensionsPopUpManager`, `BrowserSidePanelManager`

### AnalyticsClient (4)

`AnalyticsClientImpl`, `ContextPlugin`, `ImmediatelyCompletingDataTask`, `ImmediatelyCompletingHTTPSession`

### AskArcComparisonTool (4)

`AskArcComparisonToolView.AskArcViewModelsContainer`, `AskArcComparisonToolWindow`, `AskArcImpressionTrackingStub`, `AskArcOptionsObject`

### BaseHomeComponents (4)

`HomePreferencesClientImpl`, `MediaPreviewRootViewController`, `MediaPreviewRootViewController.Backdrop`, `MediaPreviewRootViewController.ModalContainer`

### FirebaseCoreInternal (4)

`FileStorage`, `HeartbeatController`, `HeartbeatStorage`, `UserDefaultsStorage`

### ImportMenuFeature (4)

`ImportDialogSheetWindow`, `ImportMenuProvider`, `PasswordImportPromptSheetWindow`, `ProfileCreationContext`

### Previews (4)

`GmailPreviewXMLParser`, `PreviewDataController`, `PreviewsDataClientImpl`, `PreviewsDataStore`

### SidebarDataStore (4)

`SidebarDataStoreFailing`, `SidebarDataStoreImpl`, `SidebarDataStoreStub`, `SidebarDataStoreTransaction`

### SidebarUI (4)

`CellSelectionStateView`, `HighlightRingView`, `SidebarContentDragPlaceholderView`, `TabHighlightView`

### TextEditor (4)

`TextEditorForwardingResponderView`, `TextEditorViewController`, `TitleEditorContainerView`, `TitleEditorTextView`

### Toasts (4)

`ShinyToastHoverState`, `ToastController`, `ToastWindow`, `ToastWindow.ViewModel`

### WebDialogFeature (4)

`LoginButton`, `WebDialogLoginView`, `WebDialogTextField`, `WebDialogWindowController`

### WindowContents (4)

`ContentToolbarInteractionTrackerImplementation`, `WindowContentToolbarInteractionTracker`, `WindowContentToolbarInteractionTracker.ExtensionPickerSession`, `WindowContentToolbarInteractionTracker.HoverSession`

### WindowProvider (4)

`FailingWindowProviding`, `StubAttributedWindowProvider`, `StubAttributedWindowProvider.WindowAttributes`, `StubWindowProvider`

### CaptureClient (3)

`CaptureClientImpl`, `CapturePasteboardReader`, `CapturePasteboardWriter`

### DialogsClient (3)

`FailingDialogsClient`, `LiveDialogsClient`, `StubDialogsClient`

### DownloadsUI (3)

`DownloadToLibrary.DownloadViewModel`, `DownloadToLibrary.ViewModel`, `DownloadToLibrary.WindowController`

### DragAndDrop (3)

`WindowInteractiveCreationManager`, `WindowInteractiveCreationPlaceholderWindow`, `WindowInteractiveCreationPlaceholderWindow.ContentView`

### EncryptionClient (3)

`EncryptionClientImpl`, `HybridEncryption`, `HybridEncryptionCache`

### FileQueryClient (3)

`FileMonitor`, `FileQueryBuilder`, `FileQueryClientImpl`

### GlobalHotkeyListenerClient (3)

`GlobalHotkeyListener`, `GlobalHotkeyListener.HotkeyRegistration`, `GlobalHotkeyManager`

### KeyboardShortcutsEducationFeature (3)

`KeyboardShortcutsEDUWindow`, `KeyboardShortcutsEDUWindowController`, `KeyboardShortcutsEducationUIManager`

### Logging (3)

`Lock`, `Logger.Storage`, `ReadWriteLock`

### Sodium (3)

`GenericHash.Stream`, `SecretStream.XChaCha20Poly1305.PullStream`, `SecretStream.XChaCha20Poly1305.PushStream`

### Tiktoken (3)

`CoreBPE`, `Encoding`, `Tiktoken`

### TopDomains (3)

`RootDomainFinder`, `RootDomainFinder.Builder`, `TLDFinder`

### TracingFeature (3)

`Delegate`, `TracingUIManager`, `TracingWindowController`

### URLLoaderClient (3)

`URLLoaderClientImpl`, `URLLoaderClientImpl.DataDelegate`, `URLLoaderClientImpl.StreamDelegate`

### WelcomeToArcFeature (3)

`OnboardingTimer`, `ViewFrames`, `WelcomeToArcHostingController`

### (extension in FirebaseFirestore):__C (2)

`FIRFirestore.Decoder`, `FIRFirestore.Encoder`

### ARCFoundation (2)

`AccessibilityActivationSignal`, `SubscriptionToken`

### AdBlocking (2)

`ManageAdBlockersDialogContext`, `ManageAdBlockersSheetWindow`

### AnalyticsPlugins (2)

`ArcCoreAnalyticsContextPlugin`, `SettingsAnalyticsContextPlugin`

### ContentSnapshotClient (2)

`ContentSnapshotClientImpl`, `ContentSnapshotClientImpl.SnapshotBox`

### FeatureFlagsClient (2)

`FeatureFlagsClientImpl`, `LaunchDarklyRemoteDataStore`

### GitHubClient (2)

`GitHubClient.VerticalFetchHistory`, `StackMembershipCache`

### GlowProgressLoadingIndicator (2)

`GlowProgressLoadingIndicatorView`, `Renderer`

### HistogramTrackingClient (2)

`AdhocHistogramTrackingModel`, `PeriodicHistogramTrackingModel`

### Icons (2)

`IconFontImageCache`, `IconFontImageCache.DrawParamsHolder`

### ImportFeature (2)

`Bookmark`, `FullDiskAccessAuthorizer`

### LibraryData (2)

`LibraryDataClientImpl`, `LibraryDataQueryBuilder`

### LifetimeTracker (2)

`LifetimeTracker`, `LifetimeTrackerUIManager`

### MediaControlsDataStore (2)

`MediaControlsDataStoreImpl`, `Wrapper`

### ReferralCodeFeature (2)

`ReferralCodeDialogSheetWindow`, `ReferralCodeMenuProvider`

### SharableObjectsFeature (2)

`SharedObjectHostingController`, `SharedObjectViewModel`

### SharedWindowFeature (2)

`ArcUndoManagerImpl`, `ArcUndoManagerImpl.UndoTarget`

### SoundEffects (2)

`SoundEffectClientImplementation`, `SoundEffectClientImplementation.Cache`

### StatusText (2)

`StatusTextView`, `StatusTextView.BackgroundView`

### TabCloseDebugger (2)

`TabCloseDebugUIManager`, `TabCloseViewModel`

### TooltipRequest (2)

`TooltipRequestIconContainerView`, `TooltipRequestView`

### TypeTravel (2)

`TypeTravelClientImpl`, `TypeTravelMainMenuIndex`

### UserNotificationsClient (2)

`Delegate`, `NotificationSettingsMonitor`

### (extension in ARCUI):__C (1)

`CALayer.PathAction`

### AIInfraProtocols (1)

`MLXActor`

### ASE2 (1)

`Normalizer`

### AboutWindow (1)

`AboutWindow`

### ActionInspectorDashboard (1)

`ActionInspectorDataStoreImpl`

### AppIconClient (1)

`AppIconClientImpl`

### ArchiveDataStoreClient (1)

`ArchiveDataStoreClientImpl`

### AskInPage (1)

`AskInPageChatThread`

### AudioProcessing (1)

`SignalProcessor`

### BackForwardList (1)

`BackForwardListMenuManager`

### BaseAssets (1)

`NoBackgroundScroller`

### BaseModels (1)

`WindowTheme.SemanticColorPalette`

### CloudKitContainerClient (1)

`SyncEngine`

### ColorPaletteDashboard (1)

`ColorPaletteController`

### CommandBarAdditionalRankingDataStoreClient (1)

`CommandBarAdditionalRankingDataStoreClientImpl`

### ContentPlaceholderClient (1)

`ContentPlaceholderClientImpl`

### DefaultBrowserPrompts (1)

`DefaultBrowserPromptWindow`

### DeveloperModeClient (1)

`DeveloperModeClientImpl`

### DocumentsClient (1)

`ArcDocumentsClient`

### DocumentsLibraryClient (1)

`DocumentsLibraryClientImpl`

### DomainParser (1)

`RulesParser`

### DynamicLogLevels (1)

`DynamicLogLevelsWindow`

### EaselLibraryClient (1)

`EaselLibraryClientImpl`

### EventSource (1)

`EventSource`

### EventStream (1)

`EventStreamParser`

### ExtensionToolbarActionClient (1)

`ToolbarActionDetailsResolver`

### FileUploaderClient (1)

`FilestackUploader`

### FirebaseSidebarSyncClient (1)

`FirebaseSidebarSyncClientImpl`

### FirebaseSidebarSyncSchemaClient (1)

`FirebaseSidebarSyncSchemaClientImpl`

### FolderIcon (1)

`FolderIconView`

### FontsManager (1)

`FontManager`

### GeoLocation (1)

`GeoLocationClientImpl`

### HTML2Markdown (1)

`HTML2Markdown`

### ImageCache (1)

`FaviconLoader`

### ImageURLLoaderClient (1)

`ImageURLLoaderClientImpl`

### ImpressionTracking (1)

`ImpressionTracker`

### InteractionInstrumentationClient (1)

`InteractionInstrumentationClientImpl`

### KeychainClient (1)

`MockKeychainClient`

### LinkRouting (1)

`LinkRoutingClientImpl`

### LiveCalendarClient (1)

`LiveCalendarClientImpl`

### LiveFoldersFeature (1)

`LiveItemIntroPopoverViewController`

### LiveNotionClient (1)

`LiveNotionClientImpl`

### MainThreadChecker (1)

`MainThreadCheckerImpl`

### MembershipCard (1)

`MembershipCardSharingPicker.Coordinator`

### MeterClient (1)

`MeterClient.Implementation`

### ModalItemSwitcher (1)

`ModalItemSwitcherWindowController`

### OpenURLClient (1)

`OpenURLEventManager`

### OrderedCollections (1)

`_HashTable.Storage`

### PermissionRequests (1)

`PermissionRequestDialogView`

### RateLimiting (1)

`SlidingWindowRateLimiter.State`

### ResponderManager (1)

`FirstResponderManager`

### SadTab (1)

`SadTabHostView`

### SessionRestorationClient (1)

`SessionRestorationClientImpl`

### SharableArcObjectsClient (1)

`SharableArcObjectsClientImpl`

### ShareSettings (1)

`ShareSettingsView`

### SharedAppFeature (1)

`SidebarAnalyticsActor`

### SidebarBanner (1)

`SidebarBannerContainerView`

### SidebarItemUI (1)

`TabTitleSourceInfo`

### SiteControlCenter (1)

`SiteControlCenterViewController`

### SpaceStyleEditor (1)

`SpaceStyleEditorViewController`

### Swift (1)

`_SwiftObject`

### SyncedPreferencesClient (1)

`SyncedPreferencesClientImpl`

### SystemPackage (1)

`_RawBuffer.Storage`

### TCAActionInspectorDashboard (1)

`TCAActionInspectorDashboardController`

### TopBarColorClient (1)

`TopBarColorClient`

### Translation (1)

`TranslateBubbleView`

### URLClientBase (1)

`URLLoaderClientTestImpl`

### URLInputter (1)

`URLInput`

### WebContent (1)

`WebContentFeatureThumbnailListener`

### WebSearch (1)

`WebKitLoaderHost`

### _LottieStub (1)

`LottieStub`

### nodeVisitor #1 in SwiftSoup (1)

`Node.setBaseUri([Swift.UInt8]) throws -> ()`

## Third-party modules

SwiftSoup (119), LaunchDarkly (51), OpenTelemetryApi (44), Sentry (36), DatadogInternal (32), DatadogCore (23), Mustache (23), Segment (20), DatadogTrace (15), SDWebImageSwiftUI (15), FirebaseStorage (8), Fuzi (8), Dependencies (7), LDSwiftEventSource (7), Motion (6), YouTubePlayerKit (6), DatadogLogs (5), FirebaseFunctions (3), ComposableArchitecture (2), Sovran (2), SwiftUIIntrospect (2), ZIPFoundation (2), AsyncAlgorithms (1)
