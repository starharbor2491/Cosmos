# ArcCore Objective-C bridge API

Every `Arc*` Objective-C class exported by `ArcCore.framework` (Chromium 156.0.8078.48 build shipped with Arc 1.170.0), with method selectors recovered via `dyld_info -objc` on the arm64 slice. Selectors only; no implementation code.

#### `ArcAIDistilBertClassifier` : NSObject  (11 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-ai_distil_bert_classifier`, `-classifierHeadFilePath`, `-configFilePath`, `-init:loraConfigJSON:configFilePath:classifierHeadFilePath:numClasses:`, `-initWithAIDistilBertClassifier:`, `-loraConfigJSON`, `-modelFilePath`, `-mutableAIDistilBertClassifier`, `-numClasses`

#### `ArcAIInferenceConfiguration` : NSObject  (7 methods)

`-.cxx_construct`, `-ai_inference_configuration`, `-init:streamAfterEveryNTokens:`, `-initWithAIInferenceConfiguration:`, `-maxTokens`, `-mutableAIInferenceConfiguration`, `-streamAfterEveryNTokens`

#### `ArcAIInferenceModel` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-ai_inference_model`, `-directory`, `-init:directory:`, `-initWithAIInferenceModel:`, `-modelType`, `-mutableAIInferenceModel`

#### `ArcAIService` : NSObject  (4 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-ai_service`, `-initWithAIService:`

#### `ArcAIServiceConfiguration` : NSObject  (13 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-appEnvironment`, `-displayName`, `-fullAppVersion`, `-init:displayName:libraryPath:libraryVersion:appEnvironment:fullAppVersion:maxRetries:timeout:error:`, `-libraryPath`, `-libraryVersion`, `-maxRetries`, `-nativeAIServiceConfig`, `-setNativeAIServiceConfig:`, `-timeout`, `-type`

#### `ArcAccessibilityActionData` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-action`, `-actionData`, `-initWithAction:`, `-initWithAction:value:`, `-setActionData:`, `-value`

#### `ArcAccessibilityTreeNode` : NSObject  (15 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accessibility_tree_node`, `-childTreeId`, `-children`, `-description`, `-initWithAccessibilityTreeNode:`, `-isClickable`, `-isEditable`, `-isFocusable`, `-name`, `-nodeId`, `-role`, `-setAccessibility_tree_node:`, `-value`

#### `ArcAddressEntrySaveRequest` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-address_entry_save_request`, `-cancel`, `-initWithAddressEntrySaveRequest:`, `-save`

#### `ArcAdhocHistogramSample` : NSObject  (5 methods)

`-initWithType:value:`, `-setType:`, `-setValue:`, `-type`, `-value`

#### `ArcAdhocHistogramSamples` : NSObject  (3 methods)

`-.cxx_destruct`, `-initWithAdhocHistogramSample:`, `-samples`

#### `ArcAnnotatedVisit` : NSObject  (63 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browserType`, `-categories`, `-clusterId`, `-faviconUrl`, `-hasUrlKeyedImage`, `-httpResponseCode`, `-init`, `-initWithAnnotatedVisit:`, `-isHidden`, `-isRedirectChainEndIncomplete`, `-isRedirectChainStartIncomplete`, `-openerVisitId`, `-originatorCacheGuid`, `-originatorVisitId`, `-pageLanguage`, `-parentTaskId`, `-passwordState`, `-redirectChain`, `-referrerUrl`, `-referringVisitId`, `-relatedSearches`, `-rootTaskId`, `-setBrowserType:`, `-setCategories:`, `-setClusterId:`, `-setFaviconUrl:`, `-setHasUrlKeyedImage:`, `-setHidden:`, `-setHttpResponseCode:`, `-setIsRedirectChainEndIncomplete:`, `-setIsRedirectChainStartIncomplete:`, `-setOpenerVisitId:`, `-setOriginatorCacheGuid:`, `-setOriginatorVisitId:`, `-setPageLanguage:`, `-setParentTaskId:`, `-setPasswordState:`, `-setRedirectChain:`, `-setReferrerUrl:`, `-setReferringVisitId:`, `-setRelatedSearches:`, `-setRootTaskId:`, `-setTabId:`, `-setTaskId:`, `-setTitle:`, `-setTransition:`, `-setUrl:`, `-setVisit:`, `-setVisitDuration:`, `-setVisitTime:`, `-setWindowId:`, `-tabId`, `-taskId`, `-title`, `-toAnnotatedVisit`, `-transition`, `-url`, `-visit`, `-visitDuration`, `-visitTime`, `-windowId`

#### `ArcAutocompleteMatch` : NSObject  (27 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-additionalData`, `-allowedToBeDefaultMatch`, `-associatedKeyword`, `-autocomplete_match`, `-contents`, `-deletable`, `-description`, `-destinationUrl`, `-destinationUrlSpec`, `-duplicates`, `-fillIntoEdit`, `-fillIntoEditAdditionalText`, `-hasTabMatch`, `-imageUrl`, `-imageUrlSpec`, `-initWithAutocompleteMatch:`, `-inlineAutocompleteText`, `-isFromKeyword`, `-isFromPrevious`, `-keyword`, `-matchType`, `-providerType`, `-relevance`, `-swapContentsAndDescription`, `-transition`

#### `ArcAutocompleteMatchAdditionalData` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-autocomplete_match_additional_data`, `-init:value:`, `-initWithAutocompleteMatchAdditionalData:`, `-key`, `-mutableAutocompleteMatchAdditionalData`, `-value`

#### `ArcAutocompleteResult` : NSObject  (4 methods)

`-.cxx_destruct`, `-combinedMatches`, `-init:perProviderMatches:`, `-perProviderMatches`

#### `ArcBackForwardList` : NSObject  (10 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-backItem`, `-backList`, `-currentItem`, `-forwardItem`, `-forwardList`, `-initWithBackForwardList:`, `-nativeBackForwardList`, `-setNativeBackForwardList:`

#### `ArcBackForwardListItem` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithBackForwardListItem:`, `-isValid`, `-nativeBackForwardListItem`, `-setNativeBackForwardListItem:`, `-title`, `-url`

#### `ArcBookmarkImportTargets` : NSObject  (6 methods)

`-.cxx_destruct`, `-initWithBookmarkBarBookmarksTargetNode:withOtherBookmarksTargetNode:`, `-setTargetNodeForBookmarkBarBookmarks:`, `-setTargetNodeForOtherBookmarks:`, `-targetNodeForBookmarkBarBookmarks`, `-targetNodeForOtherBookmarks`

#### `ArcBookmarkTreeNode` : NSObject  (19 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-dateAdded`, `-dateFolderModified`, `-faviconUrl`, `-index`, `-initWithBookmarkTreeNode:`, `-isFolder`, `-isUrl`, `-isValid`, `-liveChildren`, `-node`, `-nodeID`, `-nodeType`, `-parentNodeID`, `-setNode:`, `-title`, `-url`, `-uuid`

#### `ArcBreadcrumb` : NSObject  (10 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-breadcrumb`, `-category`, `-data`, `-fileId`, `-initWithBreadcrumb:`, `-line`, `-message`, `-setBreadcrumb:`

#### `ArcBrowser` : NSObject  (40 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-autocomplete:cursorPosition:preventInlineAutocomplete:startFresh:keyword:error:completion:`, `-browserCreateParams`, `-browserDelegate`, `-canRestoreWebContentsWithSessionId:`, `-context`, `-createWebContents:`, `-deleteAutocompleteMatch:`, `-executeExtensionAction:`, `-getAllCookies:`, `-getAllCookies:completion:`, `-initWithBrowser:`, `-isCastEnabled`, `-isEqual:`, `-isInitialized`, `-isJavaScriptFromAppleEventsAllowed`, `-moveExtension:targetIndex:`, `-nativeBrowser`, `-pinExtension:`, `-removeCookie:withName:`, `-restoreForeignTab:`, `-restoreWebContentsWithSessionId:`, `-saveCookiesToDisk`, `-sessionId`, `-setBrowserDelegate:`, `-setCookie:withCookie:`, `-setDelegate:`, `-setNativeBrowser:`, `-setWindow:`, `-setWindowIdentifier:`, `-showExtensionContextMenu:`, `-sidePanel`, `-takeOwnershipOfWebContents:`, `-toggleJavaScriptFromAppleEventsAllowed`, `-triggerExtensionOmniboxInput:inputText:disposition:`, `-tryToCloseSkipBeforeUnloadHandlers:callback:`, `-type`, `-unpinExtension:`, `-windowIdentifier`

#### `ArcBrowserApplication` : NSObject  (61 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-availableBrowserContextAttributes`, `-availableImportSourceProfiles:`, `-availableImportSources:`, `-beginImportSequence`, `-browserApplication`, `-browserApplicationDelegate`, `-cancelUrlLoad:`, `-createAIService:`, `-createBrowser:withDelegate:forWindow:`, `-createBrowserContext:isHidden:type:completion:error:`, `-createPopupBrowser:withDelegate:`, `-debugProperties`, `-deleteBrowserContext:error:`, `-devToolsWebSocketDebugURL`, `-disableAccessibility`, `-enableAccessibilityForScreenReader`, `-endImportSequence`, `-ensureBasicAccessibilityEnabled`, `-frameForDisplayId:error:`, `-getBase64EncodedEncryptionKey`, `-getBrowserContext:type:`, `-getEnterpriseDeviceID`, `-getGPULogMessages`, `-getHistogramsJSON`, `-getNonDefaultFlags:`, `-init`, `-init:`, `-initialize:`, `-isEncryptionAvailable`, `-isFeatureEnabled:`, `-loadBrowserContext:type:completion:`, `-loadImportSourceProfiles:completion:`, `-loadUrl:withDelegate:`, `-localState`, `-networkActivityMonitor`, `-quit`, `-restoreBrowser:withSessionID:browserCreatedCallback:finishedCallback:`, `-run`, `-setAccessibilityObserver:`, `-setAllFlagsToDefault:`, `-setArtifactAllowedScriptSources:`, `-setBlockLists:`, `-setBreadcrumbCallback:`, `-setBrowserApplication:`, `-setBrowserApplicationDelegate:`, `-setDumpWithoutCrashingCallback:`, `-setExcludedDomains:`, `-setFeatureEnabled:enabled:`, `-setFreeMemoryTargetOnCriticalMemoryPressure:`, `-setHistogramSamplesDelegate:`, `-setIntFeatureValue:value:`, `-setLocalState:`, `-setNotificationCenter:`, `-setOnWebContentsCloseDebugLogCallback:`, `-setStringFeatureValue:value:`, `-showTaskManager`, `-tracingController`, `-tryToTerminate:`, `-version`

#### `ArcBrowserApplicationConfiguration` : NSObject  (11 methods)

`-.cxx_destruct`, `-applicationID`, `-argc`, `-argv`, `-init:argv:profilePath:applicationID:isProduction:sessionRestorationPolicy:shouldLoadAllProfilesAtStartup:quitRunLoopOnTermination:userDefaultsSuiteName:`, `-isProduction`, `-profilePath`, `-quitRunLoopOnTermination`, `-sessionRestorationPolicy`, `-shouldLoadAllProfilesAtStartup`, `-userDefaultsSuiteName`

#### `ArcBrowserApplicationDebugProperty` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithDebugProperty:`, `-name`, `-property`, `-setProperty:`, `-value`

#### `ArcBrowserContext` : NSObject  (18 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-bookmarkObservers`, `-browser_context`, `-contextDelegate`, `-downloads`, `-effects`, `-extensions`, `-history`, `-id`, `-initWithBrowserContext:`, `-metrics`, `-pageContentExtraction`, `-preferences`, `-setBookmarkObservers:`, `-setContextDelegate:`, `-setUserVisibleName:`, `-userVisibleName`

#### `ArcBrowserContextAttributes` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browser_context_attributes`, `-directoryBasename`, `-initWithBrowserContextAttributes:`, `-setBrowser_context_attributes:`, `-userColor`, `-userVisibleName`

#### `ArcBrowserContextAutocomplete` : NSObject  (5 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-autocomplete:cursorPosition:preventInlineAutocomplete:completion:`, `-initWithAutocompleteController:`, `-stop`

#### `ArcBrowserContextDevTools` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browser_context_dev_tools`, `-close`, `-initWithBrowserContextDevTools:`, `-webContents`

#### `ArcBrowserContextDownloads` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browser_context_downloads`, `-downloadsDelegate`, `-initWithBrowserContextDownloads:`, `-initWithBrowserContextDownloads:forBrowserContext:`, `-owner`, `-setDownloadsDelegate:`, `-setOwner:`

#### `ArcBrowserContextEffects` : NSObject  (17 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browser_context_effects`, `-initWithBrowserContextEffects:`, `-initWithBrowserContextEffects:forBrowserContext:`, `-owner`, `-registerColorFilter:forHostPattern:`, `-registerColorScheme:forHostPattern:`, `-registerScript:withIdentifier:forHostPattern:`, `-registerStylesheet:withIdentifier:forHostPattern:`, `-registerZoomFactor:forHostPattern:`, `-setOwner:`, `-unregisterColorFilter:`, `-unregisterColorScheme:`, `-unregisterScript:`, `-unregisterStylesheet:`, `-unregisterZoomFactor:`

#### `ArcBrowserContextExtensions` : NSObject  (25 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browserContextExtensions`, `-disableExtension:`, `-enableExtension:`, `-executeExtensionCommand:commandName:`, `-extensionsDelegate`, `-getAllExtensionCommands`, `-getExtensionInfo:`, `-getPinnedExtensionOrder`, `-hash`, `-initWithBrowserContextExtensions:forBrowserContext:`, `-installExtensionFromUnpackedPath:completion:`, `-installExtensionFromWebstore:unattended:completion:`, `-isEqual:`, `-isExtensionSystemReady`, `-listExtensions`, `-owner`, `-reloadExtension:`, `-runJSInExtensionBackgroundPage:js_code:`, `-setDelegate:`, `-setExtensionsDelegate:`, `-setOwner:`, `-setPinnedExtensionOrder:`, `-uninstallExtension:`

#### `ArcBrowserContextHistory` : NSObject  (11 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browser_context_history`, `-historyDelegate`, `-initWithBrowserContextHistory:`, `-initWithBrowserContextHistory:forBrowserContext:`, `-owner`, `-setHistoryDelegate:`, `-setOwner:`, `-setVisitObserverBridge:`, `-visitObserverBridge`

#### `ArcBrowserContextID` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-directoryBasename`, `-id`, `-initWithBrowserContextID:`, `-isIncognito`

#### `ArcBrowserContextPageContentExtraction` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browser_context_page_content_extraction`, `-initWithBrowserContextPageContentExtraction:`, `-initWithBrowserContextPageContentExtraction:forBrowserContext:`, `-owner`, `-setOwner:`

#### `ArcBrowserContextPreferences` : NSObject  (27 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-addObserver:`, `-autoOpenFileExtensions`, `-browser_context_preferences`, `-browser_context_preferences_observer_bridges`, `-canEnableCreditCardsSaving`, `-canEnablePasswordSaving`, `-clearAutoOpenFiles`, `-creditCardsSavingEnabled`, `-initWithBrowserContextPreferences:`, `-initWithBrowserContextPreferences:forBrowserContext:`, `-keywordSearchSpaceTriggeringEnabled`, `-notificationPermissionRequestsEnabled`, `-owner`, `-passwordSavingEnabled`, `-promptForDownloadPath`, `-removeObserver:`, `-searchSuggestEnabled`, `-setBrowser_context_preferences_observer_bridges:`, `-setCreditCardsSavingEnabled:`, `-setKeywordSearchSpaceTriggeringEnabled:`, `-setNotificationPermissionRequestsEnabled:`, `-setOwner:`, `-setPasswordSavingEnabled:`, `-setPromptForDownloadPath:`, `-setSearchSuggestEnabled:`

#### `ArcBrowserCreateParams` : NSObject  (12 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-canFullscreen`, `-canMaximize`, `-canResize`, `-initWithBrowserCreateParams:`, `-initialBounds`, `-initialOriginSpecified`, `-nativeCreateParams`, `-pipSize`, `-setNativeCreateParams:`, `-userTitle`

#### `ArcBrowserSidePanel` : NSObject  (13 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-didFinishClosing`, `-getEntryInfoForTabWithSessionId:`, `-initWithSidePanel:`, `-nativeSidePanel`, `-requestClose`, `-setDelegate:`, `-setNativeSidePanel:`, `-setSidePanelDelegate:`, `-sidePanelDelegate`, `-title`, `-webContents`

#### `ArcBrowserSidePanelEntryInfo` : NSObject  (7 methods)

`-.cxx_destruct`, `-cachedWebContents`, `-extensionId`, `-hasActiveEntry`, `-setCachedWebContents:`, `-setExtensionId:`, `-setHasActiveEntry:`

#### `ArcColor` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-a`, `-b`, `-color`, `-g`, `-initWithColor:`, `-r`, `-setColor:`

#### `ArcColor4f` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-a`, `-b`, `-color4f`, `-g`, `-initWithColor4f:`, `-r`, `-setColor4f:`

#### `ArcCommandBarRankingCandidate` : NSObject  (19 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-archetype`, `-candidateID`, `-command_bar_ranking_candidate`, `-destination`, `-freqEver`, `-init:archetype:destination:title:url:lastNavSeconds:freqEver:typedCount:siteEngagement:isExactURLMatch:isBaseDomainMatch:isTitlePrefix:titleEmbedding:`, `-initWithCommandBarRankingCandidate:`, `-isBaseDomainMatch`, `-isExactURLMatch`, `-isTitlePrefix`, `-lastNavSeconds`, `-mutableCommandBarRankingCandidate`, `-siteEngagement`, `-title`, `-titleEmbedding`, `-typedCount`, `-url`

#### `ArcCommandBarRankingEvaluation` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-command_bar_ranking_evaluation`, `-evaluationDurationMs`, `-init:numExamplesEvaluated:evaluationDurationMs:`, `-initWithCommandBarRankingEvaluation:`, `-metrics`, `-mutableCommandBarRankingEvaluation`, `-numExamplesEvaluated`

#### `ArcCommandBarRankingExample` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-command_bar_ranking_example`, `-init:candidates:selectedIndex:`, `-initWithCommandBarRankingExample:`, `-mutableCommandBarRankingExample`, `-selectedIndex`

#### `ArcCommandBarRankingInput` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-command_bar_ranking_input`, `-init:`, `-initWithCommandBarRankingInput:`, `-mutableCommandBarRankingInput`, `-queryEmbedding`

#### `ArcCommandBarRankingModel` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-command_bar_ranking_model`, `-directory`, `-init:version:`, `-initWithCommandBarRankingModel:`, `-mutableCommandBarRankingModel`, `-version`

#### `ArcCommandBarRankingResult` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-candidateID`, `-command_bar_ranking_result`, `-init:score:`, `-initWithCommandBarRankingResult:`, `-mutableCommandBarRankingResult`, `-score`

#### `ArcCommandBarRankingTensor` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-command_bar_ranking_tensor`, `-data`, `-init:shape:data:`, `-initWithCommandBarRankingTensor:`, `-mutableCommandBarRankingTensor`, `-name`, `-shape`

#### `ArcCommandBarRankingTrainingResult` : NSObject  (17 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-command_bar_ranking_training_result`, `-deltaNorm`, `-deltaToWeightRatio`, `-failureReason`, `-gradientNormMax`, `-gradientNormMean`, `-init:failureReason:delta:modelName:modelVersion:numSamples:lossesPerEpoch:gradientNormMean:gradientNormMax:deltaNorm:deltaToWeightRatio:trainingDurationMs:`, `-initWithCommandBarRankingTrainingResult:`, `-lossesPerEpoch`, `-modelName`, `-modelVersion`, `-mutableCommandBarRankingTrainingResult`, `-numSamples`, `-outcome`, `-trainingDurationMs`

#### `ArcConfirmInfobar` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accept`, `-confirm_infobar`, `-initWithConfirmInfobar:`, `-messageText`

#### `ArcContentConversionService` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-convertHtmlToMarkdown:url:linkStyle:strategy:urlTransform:skipNoscript:passThroughInputElements:metaTagsToCapture:deduplicateMetaTagContent:completion:`, `-init`, `-initWithImpl:`, `-initializeWithLibraryPath:displayName:libraryVersion:appEnvironment:fullAppVersion:callback:`, `-isAvailable`, `-setUser:email:callback:`

#### `ArcContentNode` : NSObject  (17 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-children`, `-content_node`, `-formActionURL`, `-formControlInfo`, `-formName`, `-hasEmphasis`, `-iframeOrigin`, `-imageAlt`, `-initWithContentNode:`, `-linkURL`, `-tableName`, `-textColor`, `-textContent`, `-textSize`, `-type`

#### `ArcContextMenuElementInfo` : NSObject  (17 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-context_menu_element_info`, `-dictionarySuggestions`, `-initWithContextMenuElementInfo:`, `-inputType`, `-isEditable`, `-linkURL`, `-misspelledWord`, `-nodeType`, `-selectionText`, `-sourceAttributeURL`, `-subFrameURL`, `-suggestedFilename`, `-topLevelURL`, `-x`, `-y`

#### `ArcCookie` : NSObject  (26 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-cookie`, `-domain`, `-expirationDate`, `-hostOnly`, `-httpOnly`, `-init`, `-initWithCookie:`, `-mutableCookie`, `-name`, `-path`, `-sameSite`, `-secure`, `-session`, `-setDomain:`, `-setExpirationDate:`, `-setHostOnly:`, `-setHttpOnly:`, `-setName:`, `-setPath:`, `-setSameSite:`, `-setSecure:`, `-setSession:`, `-setValue:`, `-value`

#### `ArcCpuInfo` : NSObject  (29 methods)

`-.cxx_destruct`, `-architecture`, `-armImplementer`, `-armPartNumber`, `-brand`, `-extFamily`, `-extModel`, `-family`, `-hasAESNI`, `-hasAVX`, `-hasAVX2`, `-hasBMI2`, `-hasBTI`, `-hasFMA3`, `-hasMMX`, `-hasMTE`, `-hasPOPCNT`, `-hasSSE`, `-hasSSE2`, `-hasSSE3`, `-hasSSE41`, `-hasSSE42`, `-hasSSSE3`, `-init`, `-isHypervisorActive`, `-model`, `-stepping`, `-type`, `-vendor`

#### `ArcCrashKeysReporter` : NSObject  (1 methods)

`+setArcCrashKeysObserver:`

#### `ArcCreditCardInfoSaveRequest` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-cancel`, `-credit_card_info_save_request`, `-initWithCreditCardInfoSaveRequest:`, `-save`

#### `ArcDevToolsConnectionDialog` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accept`, `-deny`, `-dialog`, `-disable`, `-initWithDevToolsConnectionDialog:`, `-setDialog:`

#### `ArcDisplayNameOrOrigin` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-display_name_or_origin`, `-initWithDisplayNameOrOrigin:`, `-isOrigin`, `-nameOrOrigin`, `-setDisplay_name_or_origin:`

#### `ArcDownloadItem` : NSObject  (21 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-canResume`, `-cancel:`, `-completedBytes`, `-currentSpeed`, `-currentState`, `-download_item`, `-id`, `-initWithDownloadItem:`, `-isDone`, `-isPaused`, `-pause`, `-remainingTimeInSeconds`, `-remove`, `-resume`, `-sourceURL`, `-startTime`, `-targetPath`, `-totalBytes`, `-webContents`

#### `ArcErrorStatus` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-crashedErrorCode`, `-error_status`, `-initWithErrorStatus:`, `-processTerminationStatus`, `-setError_status:`

#### `ArcExtensionCommand` : NSObject  (10 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-commandDescription`, `-commandName`, `-extensionId`, `-extension_command`, `-initWithExtensionCommand:`, `-isGlobal`, `-setExtension_command:`, `-shortcut`

#### `ArcExtensionInfo` : NSObject  (19 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-description`, `-enabled`, `-extension_info`, `-fromWebstore`, `-hasAction`, `-icon`, `-id`, `-init`, `-initWithExtensionInfo:`, `-mutableExtensionInfo`, `-name`, `-numRatings`, `-omniboxKeyword`, `-permissions`, `-rating`, `-url`, `-version`

#### `ArcExtensionRuntimeError` : NSObject  (11 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-contextURL`, `-extensionID`, `-extension_runtime_error`, `-fromIncognito`, `-initWithExtensionRuntimeError:`, `-message`, `-severity`, `-source`, `-stackTrace`

#### `ArcExtensionRuntimeErrorStackFrame` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-columnNumber`, `-extension_runtime_error_stack_frame`, `-function`, `-initWithExtensionRuntimeErrorStackFrame:`, `-lineNumber`, `-source`

#### `ArcExtensionToolbarAction` : NSObject  (11 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accessibleName`, `-enabled`, `-extension_toolbar_action`, `-icon`, `-id`, `-initWithExtensionToolbarAction:`, `-pinnedPosition`, `-setExtension_toolbar_action:`, `-tooltipText`

#### `ArcExternalProtocolDialog` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accept:`, `-cancel`, `-close`, `-external_protocol_dialog`, `-initWithExternalProtocolDialog:`, `-origin`, `-programName`

#### `ArcExtractedPageContent` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-extracted_page_content`, `-extractionTime`, `-initWithExtractedPageContent:`, `-rootNode`, `-title`, `-url`

#### `ArcFindResult` : NSObject  (3 methods)

`-activeMatchOrdinal`, `-initWithFindResult:`, `-numMatches`

#### `ArcFindTextWithDirectiveResult` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-directive`, `-find_text_with_directive_result`, `-initWithFindTextWithDirectiveResult:`, `-result`, `-setFind_text_with_directive_result:`

#### `ArcFormControlInfo` : NSObject  (12 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-controlType`, `-fieldName`, `-fieldValue`, `-form_control_info`, `-initWithFormControlInfo:`, `-isChecked`, `-isRedacted`, `-isRequired`, `-placeholder`, `-selectOptions`

#### `ArcFreezingVoteToken` : NSObject  (5 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-clearVote`, `-freezing_vote_token`, `-initWithFreezingVoteToken:`

#### `ArcGPULogMessage` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-gpu_log_message`, `-header`, `-initWithGPULogMessage:`, `-message`, `-setGpu_log_message:`, `-severity`

#### `ArcHSLAMatrix` : NSObject  (23 methods)

`-hslaMatrix`, `-initWithMatrix:`, `-m0`, `-m1`, `-m10`, `-m11`, `-m12`, `-m13`, `-m14`, `-m15`, `-m16`, `-m17`, `-m18`, `-m19`, `-m2`, `-m3`, `-m4`, `-m5`, `-m6`, `-m7`, `-m8`, `-m9`, `-setHslaMatrix:`

#### `ArcHistogramSample` : NSObject  (6 methods)

`-.cxx_destruct`, `-browserInSession`, `-browserIsPlayingAudio`, `-browserIsVisible`, `-initWithHistogramSample:`, `-value`

#### `ArcHistogramSamples` : NSObject  (39 methods)

`-.cxx_destruct`, `-aiServiceMemoryFootprintMb`, `-audioServiceMemoryFootprintMb`, `-averageAIServiceCpuPercent`, `-averageBrowserCpuPercent`, `-averageExtensionEventProcessCpuPercent`, `-averageExtensionPersistentProcessCpuPercent`, `-averageGpuProcessCpuPercent`, `-averageNetworkProcessCpuPercent`, `-averageRendererProcessCpuPercent`, `-averageTotalCpuDuringFullscreenVideoPercent`, `-averageTotalCpuPercent`, `-averageTotalCpuWhenIdleForegroundPercent`, `-averageTotalCpuWhileInBackgroundPercent`, `-averageTotalCpuWithInteractionPercent`, `-averageTotalCpuWithNavigationPercent`, `-batteryDischargeRate`, `-batteryDischargeRateNavigation`, `-batteryDischargeRateWhileInBackground`, `-browserMemoryFootprintMb`, `-extensionMemoryFootprintMb`, `-gpuMemoryFootprintMb`, `-idleWakeupsTotal`, `-idleWakeupsTotalWhileInBackground`, `-initWithPeriodicHistogramSample:`, `-memoryPressureWindowDurationCriticalToModerate`, `-memoryPressureWindowDurationCriticalToNone`, `-memoryPressureWindowDurationModerateToCritical`, `-memoryPressureWindowDurationModerateToNone`, `-networkServiceMemoryFootprintMb`, `-rendererMemoryFootprintMb`, `-totalGpuMappedMemoryMb`, `-totalMemoryFootprintMb`, `-totalPrivateSwapFootprintMb`, `-totalRendererMemoryFootprintMb`, `-totalResidentSetMb`, `-totalSharedMemoryFootprintMb`, `-totalTileMemoryMb`, `-utilityMemoryFootprintMb`

#### `ArcHistoryDeletion` : NSObject  (13 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-deletedItems`, `-deletedVisitIds`, `-faviconUrls`, `-hasTimeRange`, `-history_deletion`, `-initWithHistoryDeletion:`, `-isAllHistory`, `-isFromExpiration`, `-restrictUrls`, `-timeRangeEnd`, `-timeRangeStart`

#### `ArcHistoryItem` : NSObject  (12 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-historyID`, `-history_item`, `-initWithHistoryItem:`, `-lastVisitTime`, `-title`, `-typedCount`, `-url`, `-urlSpec`, `-visitCount`, `-visitTime`

#### `ArcHistoryQueryOptions` : NSObject  (16 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-beginTime`, `-duplicateHandlingPolicy`, `-endTime`, `-matchingAlgorithm`, `-maxResults`, `-options`, `-searchText`, `-setBeginTime:`, `-setDuplicateHandlingPolicy:`, `-setEndTime:`, `-setMatchingAlgorithm:`, `-setMaxResults:`, `-setOptions:`, `-setSearchText:`

#### `ArcHtmlToMarkdownResult` : NSObject  (8 methods)

`-.cxx_destruct`, `-body`, `-initWithBody:title:references:selectorsApplied:selectorsContentPct:metaTags:`, `-metaTags`, `-references`, `-selectorsApplied`, `-selectorsContentPct`, `-title`

#### `ArcHungRendererDialog` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-crashProcess`, `-dialog`, `-initWithHungRendererDialog:`, `-setDialog:`, `-wait`

#### `ArcImage` : NSObject  (13 methods)

`+dangerouslyDecodeFromData:scale:`, `+decodeFromData:scale:completion:`, `+decodeFromData:scale:desiredWidth:desiredHeight:maxDecodedBytes:completion:`, `-.cxx_construct`, `-.cxx_destruct`, `-image`, `-init`, `-initWithArcImage:`, `-isNull`, `-logicalHeight`, `-logicalWidth`, `-nsImage`, `-setImage:`

#### `ArcImageRep` : NSObject  (17 methods)

`+createFromPixelDataBGRA8888:height:scale:rowBytes:pixelData:`, `+dangerouslyDecodeFromData:scale:`, `+decodeFromData:scale:completion:`, `+decodeFromData:scale:desiredWidth:desiredHeight:maxDecodedBytes:completion:`, `-.cxx_construct`, `-.cxx_destruct`, `-copyPixelDataBGRA8888`, `-encodeToJPEGWithQuality:`, `-encodeToPNGWithMethod:`, `-imageRep`, `-init`, `-initWithArcImageRep:`, `-isNull`, `-pixelHeight`, `-pixelWidth`, `-setImageRep:`, `-toNSImage`

#### `ArcImportSource` : NSObject  (3 methods)

`-initWithImportSource:`, `-sourceID`, `-type`

#### `ArcImportSourceProfile` : NSObject  (14 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-appPath`, `-availableExtensions:`, `-constraints`, `-initWithImportSourceProfile:`, `-initWithSafariExportedData:profileName:name:categories:`, `-name`, `-profile`, `-profileName`, `-setProfile:`, `-sourcePath`, `-supportedCategories`, `-type`

#### `ArcKeyEventData` : NSObject  (6 methods)

`-.cxx_destruct`, `-domCode`, `-eventType`, `-initWithEventType:domCode:key:windowsVirtualKeyCode:`, `-key`, `-windowsVirtualKeyCode`

#### `ArcKeyboardAccelerator` : NSObject  (3 methods)

`-initWithAccelerator:`, `-key`, `-modifiers`

#### `ArcLocalState` : NSObject  (12 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-addPrefChangeCallback:callback:error:`, `-getBoolean:error:`, `-getBrowserPolicy:error:`, `-getDictionary:error:`, `-getInteger:error:`, `-getList:error:`, `-getString:error:`, `-initWithLocalState:`, `-localState`, `-removePrefChangeCallback:error:`

#### `ArcLoginCredentials` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithLoginCredentials:`, `-login_credentials`, `-password`, `-url`, `-username`

#### `ArcLoginCredentialsSaveRequest` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-cancel`, `-initWithLoginCredentialsSaveRequest:`, `-isUpdate`, `-login_credentials_save_request`, `-neverAskAgain`, `-save`

#### `ArcMediaImage` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-dealloc`, `-initWithMediaImage:`, `-nativeMediaImage`, `-setNativeMediaImage:`, `-sizes`, `-src`, `-type`

#### `ArcMediaPosition` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-currentTime`, `-duration`, `-endOfMedia`, `-initWithMediaPosition:`, `-media_position`, `-playbackRate`

#### `ArcMemoryDumpMetric` : NSObject  (5 methods)

`-.cxx_destruct`, `-initWithName:units:value:`, `-name`, `-units`, `-value`

#### `ArcMemoryDumpProvider` : NSObject  (4 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-dealloc`, `-initWithName:dataProvider:`

#### `ArcMenuItemModel` : NSObject  (21 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accelerator`, `-accessibleName`, `-activated`, `-hasAccelerator`, `-icon`, `-initWithMenuItemModel:`, `-isAlerted`, `-isChecked`, `-isEnabled`, `-isNewFeature`, `-isVisible`, `-label`, `-logicalType`, `-menu_item_model`, `-menu_item_model_delegate_bridge`, `-setDelegate:`, `-setMenu_item_model_delegate_bridge:`, `-submenuModel`, `-type`

#### `ArcMenuModel` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithMenuModel:`, `-items`, `-menuWillClose`, `-menuWillShow`, `-menu_model`

#### `ArcMetaTagEntry` : NSObject  (4 methods)

`-.cxx_destruct`, `-initWithKey:value:`, `-key`, `-value`

#### `ArcMetaTagSelector` : NSObject  (4 methods)

`-.cxx_destruct`, `-initWithKind:value:`, `-kind`, `-value`

#### `ArcMetrics` : NSObject  (5 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browser_context_metrics`, `-getAllSiteEngagementDetails`, `-initWithBrowserContextMetrics:`

#### `ArcMostVisitedURL` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithMostVisitedSite:`, `-most_visited_site`, `-title`, `-url`, `-urlSpec`

#### `ArcNavigation` : NSObject  (10 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-didRedirectToOtherTab`, `-hash`, `-init:`, `-isEqual:`, `-nativeNavigation`, `-responseHeaders`, `-responseStatusCode`, `-url`

#### `ArcNavigationAction` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithNavigationAction:`, `-nativeNavigationAction`, `-navigationDisposition`, `-navigationType`, `-referrer`, `-setNativeNavigationAction:`, `-url`

#### `ArcNetworkActivityMonitor` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-hash`, `-init:`, `-isEqual:`, `-isLogging`, `-networkActivityMonitor`, `-startLogging:with:error:`

#### `ArcNetworkLoggingConfiguration` : NSObject  (10 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-filePath`, `-init`, `-initWithNetworkLoggingConfiguration:`, `-loggingDurationInSeconds`, `-network_logging_configuration`, `-setFilePath:`, `-setLoggingDurationInSeconds:`, `-setNetwork_logging_configuration:`

#### `ArcNomicEmbedTextItem` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-init:task:`, `-initWithNomicEmbedTextItem:`, `-mutableNomicEmbedTextItem`, `-nomic_embed_text_item`, `-task`, `-text`

#### `ArcNomicEmbedTextModel` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-directory`, `-init:version:`, `-initWithNomicEmbedTextModel:`, `-mutableNomicEmbedTextModel`, `-nomic_embed_text_model`, `-version`

#### `ArcNotification` : NSObject  (34 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-browserContext`, `-browserContextLocalID`, `-browserContextQualifiedID`, `-buttons`, `-category`, `-contextMessage`, `-didClick:input:`, `-didClickSettings`, `-didClose:`, `-didReceiveResponse:`, `-documentURL`, `-icon`, `-iconURL`, `-id`, `-image`, `-initWithNotification:`, `-items`, `-message`, `-notification`, `-origin`, `-permanent`, `-priority`, `-progress`, `-progressStatus`, `-renotify`, `-setIconURL:`, `-setNotification:`, `-showSettingsButton`, `-showSnoozeButton`, `-smallImage`, `-title`, `-type`

#### `ArcNotificationButton` : NSObject  (9 methods)

`-.cxx_destruct`, `-icon`, `-isTextInput`, `-placeholder`, `-setIcon:`, `-setIsTextInput:`, `-setPlaceholder:`, `-setTitle:`, `-title`

#### `ArcNotificationItem` : NSObject  (5 methods)

`-.cxx_destruct`, `-message`, `-setMessage:`, `-setTitle:`, `-title`

#### `ArcOverscrollBehavior` : NSObject  (5 methods)

`-init`, `-setX:`, `-setY:`, `-x`, `-y`

#### `ArcOverscrollParams` : NSObject  (4 methods)

`-.cxx_destruct`, `-init`, `-overscrollBehavior`, `-setOverscrollBehavior:`

#### `ArcPasteAndGoClassification` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-destinationURL`, `-initWithPasteAndGoClassification:`, `-menuTitle`, `-paste_and_go_classification`

#### `ArcPerformanceController` : NSObject  (6 methods)

`+isBatterySaverModeActive`, `+isBatterySaverModeTemporarilyDisabled`, `+setArcPerformanceObserver:`, `+setHighEfficiencyModeEnabled:`, `+simulateLowBatteryStateForDuration:`, `+temporarilyDisableBatterySaverMode:`

#### `ArcPermissionRequest` : NSObject  (7 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-additionalData`, `-initWithPermissionRequest:`, `-originUrl`, `-permission_request`, `-type`

#### `ArcRedirectEntry` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-hidden`, `-initWithRedirectEntry:`, `-redirectType`, `-redirect_entry`, `-title`, `-url`

#### `ArcReference` : NSObject  (4 methods)

`-.cxx_destruct`, `-initWithReferenceText:minimumCharacterCount:`, `-minimumCharacterCount`, `-referenceText`

#### `ArcSearchEngine` : NSObject  (12 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-faviconUrl`, `-init:keyword:url:faviconUrl:`, `-initWithSearchEngineTemplateURL:`, `-isPrepopulated`, `-keyword`, `-mutableSearchEngineTemplateURL`, `-name`, `-search_engine_template_url`, `-status`, `-url`

#### `ArcSecureContext` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-context`, `-initWithSecureContext:`, `-setContext:`, `-state`

#### `ArcSelectOption` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithSelectOption:`, `-isDisabled`, `-isSelected`, `-select_option`, `-text`, `-value`

#### `ArcSessionID` : NSObject  (8 methods)

`-.cxx_construct`, `-hash`, `-identifier`, `-initWithID:`, `-initWithSessionId:`, `-isEqual:`, `-sessionId`, `-setSessionId:`

#### `ArcSessionNavigation` : NSObject  (12 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-faviconURL`, `-hasPostData`, `-initWithSessionNavigation:`, `-isOverridingUserAgent`, `-originalRequestURL`, `-referrerURL`, `-session_navigation`, `-timestamp`, `-title`, `-virtualURL`

#### `ArcSessionTab` : NSObject  (11 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-currentNavigationIndex`, `-groupId`, `-initWithSessionTab:`, `-isPinned`, `-lastActiveTime`, `-navigations`, `-session_tab`, `-setCurrentNavigationIndex:`, `-setNavigations:`

#### `ArcSessionTabGroup` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-color`, `-groupId`, `-initWithSessionTabGroup:`, `-isCollapsed`, `-nativeSessionTabGroup`, `-setNativeSessionTabGroup:`, `-title`

#### `ArcSessionWindow` : NSObject  (11 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithSessionWindow:`, `-lastModified`, `-nativeSessionWindow`, `-selectedTabIndex`, `-setNativeSessionWindow:`, `-showState`, `-tabGroups`, `-tabs`, `-windowType`

#### `ArcSiteEngagementDetails` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithSiteEngagementDetails:`, `-score`, `-site_engagement_details`, `-url`

#### `ArcSiteSettingInfo` : NSObject  (13 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-contentSettingsType`, `-info`, `-init`, `-initWithSiteSettingInfo:`, `-originUrl`, `-permissionType`, `-setContentSettingsType:`, `-setInfo:`, `-setOriginUrl:`, `-setSiteSetting:`, `-siteSetting`

#### `ArcSpake2Context` : NSObject  (5 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-generateMessageWithPassword:error:`, `-initWithRole:myName:theirName:`, `-processMessage:error:`

#### `ArcTabGroupInfo` : NSObject  (14 methods)

`-.cxx_destruct`, `-collapsed`, `-color`, `-extensionGroupId`, `-groupId`, `-init`, `-setCollapsed:`, `-setColor:`, `-setExtensionGroupId:`, `-setGroupId:`, `-setTabSessionIds:`, `-setTitle:`, `-tabSessionIds`, `-title`

#### `ArcTabGroupProperties` : NSObject  (12 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-collapsed`, `-color`, `-init`, `-initWithTabGroupProperties:`, `-setCollapsed:`, `-setColor:`, `-setTab_group_properties:`, `-setTitle:`, `-tab_group_properties`, `-title`

#### `ArcTabGroupResult` : NSObject  (10 methods)

`-.cxx_destruct`, `-error`, `-extensionGroupId`, `-groupId`, `-init`, `-setError:`, `-setExtensionGroupId:`, `-setGroupId:`, `-setSuccess:`, `-success`

#### `ArcTracingConfiguration` : NSObject  (11 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-filePath`, `-init`, `-privacyFilteringEnabled`, `-setFilePath:`, `-setPrivacyFilteringEnabled:`, `-setTracingConfiguration:`, `-setTracingDuration:`, `-tracingConfiguration`, `-tracingDuration`

#### `ArcTracingController` : NSObject  (13 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-abort`, `-bridge`, `-hash`, `-init:`, `-isEqual:`, `-isTracing`, `-setBridge:`, `-setDelegate:`, `-start:`, `-stop`, `-tracingController`

#### `ArcURLLoadCancellationToken` : NSObject  (5 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithToken:`, `-setToken:`, `-token`

#### `ArcURLLoadConfiguration` : NSObject  (29 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-blockLocalRequest`, `-cachePolicy`, `-config`, `-followRedirects`, `-headers`, `-initWithConfig:`, `-method`, `-payload`, `-payloadContentType`, `-payloadData`, `-payloadFileURL`, `-setBlockLocalRequest:`, `-setCachePolicy:`, `-setConfig:`, `-setFollowRedirects:`, `-setHeaders:`, `-setMethod:`, `-setPayload:`, `-setPayloadContentType:`, `-setPayloadData:`, `-setPayloadFileURL:`, `-setStreamResponseData:`, `-setTimeout:`, `-setUrl:`, `-streamResponseData`, `-timeout`, `-url`

#### `ArcURLUtilities` : NSObject  (2 methods)

`+effectiveTopLevelDomainFromHost:includePrivateRegistries:`, `+formatHostForDisplay:`

#### `ArcVisitCategory` : NSObject  (8 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-categoryId`, `-initCategoryId:weight:`, `-initWithVisitCategory:`, `-mutableVisitCategory`, `-visit_category`, `-weight`

#### `ArcWebContents` : NSObject  (137 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accessibilityTreeForTreeId:`, `-activateTab:`, `-aiAgent`, `-applyColorFilter:`, `-backForwardList`, `-blockedResourceCount`, `-bootstrapRendering`, `-bootstrapRenderingComplete`, `-canGoBack`, `-canGoForward`, `-captureFullPage:`, `-captureRegion:completion:`, `-captureViewport:`, `-clearSiteDataAndReload:`, `-clone`, `-consumeExternalProtocolLaunchPermission`, `-contentsMimeType`, `-deviceScaleFactor`, `-diagnosticId`, `-disallowDownloads`, `-discard`, `-emitFreezingVote:`, `-errorStatus`, `-executeJavascript:completion:`, `-executeJavascript:reason:completion:`, `-exitFullscreen`, `-favicon`, `-find:forward:matchCase:findMatch:completion:`, `-findTextWithDirectives:completion:`, `-freeformTextFieldActive`, `-hadFormOrUserEdits`, `-hasDirtyTextField`, `-hasFocus`, `-ignoreDisablePiPAttribute:`, `-initWithWebContents:`, `-inputEvent`, `-insertStylesheet:stylesheet:`, `-isBlockingJavascriptPopups`, `-isFullscreen`, `-isInitialized`, `-isLoading`, `-isReadyToDisplay`, `-isScaleFactorOne`, `-isScrollOffsetAtTop`, `-javascriptPopupsDisplayedCount`, `-loadProgress`, `-navigationID`, `-passwordTextFieldActive`, `-pdfController`, `-pendingRenderFrameViewportSize`, `-performAccessibilityAction:treeId:nodeId:`, `-print`, `-removeColorFilter`, `-removeColorScheme`, `-removeStylesheet:`, `-resetZoomAndScaleFactors`, `-revertTranslation`, `-rootBackgroundColor`, `-rootFrameAccessibilityTreeId`, `-save`, `-selectedText`, `-sendKeyEvent:treeId:`, `-setAccessibilityOverrideActive:`, `-setActionsDelegate:`, `-setBackForwardList:`, `-setBlockedResourceCount:`, `-setCanGoBack:`, `-setCanGoForward:`, `-setDisallowDownloads:`, `-setFavicon:`, `-setFreeformTextFieldActive:`, `-setHadFormOrUserEdits:`, `-setHasDirtyTextField:`, `-setHasFocus:`, `-setInputEvent:`, `-setIsBlockingJavascriptPopups:`, `-setIsLoading:`, `-setIsReadyToDisplay:`, `-setLoadProgress:`, `-setNavigationDelegate:`, `-setNavigationID:`, `-setPasswordTextFieldActive:`, `-setPdfController:`, `-setPendingRenderFrameViewportSize:`, `-setRootBackgroundColor:`, `-setSafeAreaInsets:left:bottom:right:`, `-setSelectedText:`, `-setState:`, `-setTabTraits:`, `-setThemeColor:`, `-setTitle:`, `-setTopBandColorDelegate:`, `-setUIDelegate:`, `-setUndoableFieldActive:`, `-setUrl:`, `-setUserActivityDelegate:`, `-setUserActivityObserver:`, `-setVisibility:`, `-setWebContentsObserver:`, `-setWeb_contents_actions_delegate_bridge:`, `-setWeb_contents_gesture_handler_bridge:`, `-setWeb_contents_navigation_delegate_bridge:`, `-setWeb_contents_top_band_color_delegate_bridge:`, `-setWeb_contents_ui_delegate_bridge:`, `-setZoomFactor:`, `-setZoomLevel:`, `-shareThisTab`, `-showBlockedPopups`, `-showCertificateDialog`, `-skipUserActivationForPiP:`, `-state`, `-stop`, `-stopFind`, `-stopSharingThisTab`, `-supportedTranslateLanguages`, `-tabTraits`, `-themeColor`, `-title`, `-translateToTargetLanguage:`, `-typeText:inFrameWIthAccessibilityTreeId:`, `-undoableFieldActive`, `-url`, `-userActivityDelegate`, `-userActivityObserver`, `-visibility`, `-webContentsObserver`, `-web_contents`, `-web_contents_actions_delegate_bridge`, `-web_contents_gesture_handler_bridge`, `-web_contents_navigation_delegate_bridge`, `-web_contents_top_band_color_delegate_bridge`, `-web_contents_ui_delegate_bridge`, `-willRunUnloadEvents`, `-zoomFactor`, `-zoomLevel`

#### `ArcWebContentsAIAgent` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithWebContentsAIAgent:`, `-sendKeyPress:`, `-sendTextInput:`, `-web_contents_ai_agent`

#### `ArcWebContentsBoostIDE` : NSObject  (10 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-boostIDEDelegateBridge`, `-initWithBoostIDE:`, `-nativeBoostIDE`, `-sendErrorResponse:jsonString:`, `-sendEvent:jsonString:`, `-sendResponse:jsonString:`, `-setBoostIDEDelegateBridge:`, `-setDelegate:`

#### `ArcWebContentsConfiguration` : NSObject  (26 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-disallowAutoplay`, `-disallowContextMenus`, `-disallowDownloads`, `-forceAllowAutoplay`, `-forceDisplayPDFInline`, `-forcedViewSize`, `-foreground`, `-initiallyHidden`, `-initiallyMuted`, `-nativeWebContentsConfiguration`, `-setDisallowAutoplay:`, `-setDisallowContextMenus:`, `-setDisallowDownloads:`, `-setForceAllowAutoplay:`, `-setForceDisplayPDFInline:`, `-setForcedViewSize:`, `-setForeground:`, `-setInitiallyHidden:`, `-setInitiallyMuted:`, `-setNativeWebContentsConfiguration:`, `-setTransparentBackground:`, `-setUntracked:`, `-transparentBackground`, `-untracked`

#### `ArcWebContentsDevTools` : NSObject  (24 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-bridge`, `-close`, `-closeProtocolConnection:`, `-currentPanel:error:`, `-execute:completion:error:`, `-hash`, `-init:`, `-inspectElementAt:`, `-isEqual:`, `-nativeDevTools`, `-open`, `-openConsoleView`, `-openInspectView`, `-openNetworkView`, `-openProtocolConnection:error:`, `-sendProtocolMessage:connectionID:error:`, `-setBridge:`, `-setDelegate:`, `-subscribe:autoEnable:notification:`, `-toolboxWebContents`, `-unsubscribe:`, `-webContents`

#### `ArcWebContentsMediaSession` : NSObject  (32 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-bridge`, `-exitPictureInPicture:error:`, `-getMediaContentTypes:`, `-hangUp:`, `-hash`, `-init:forWebContents:`, `-isEqual:`, `-nativeMediaSession`, `-notifyAutoPipTabActivationChanged:error:`, `-owner`, `-pause:`, `-pipController`, `-play:`, `-playNextTrack:`, `-playPreviousTrack:`, `-position`, `-raise:`, `-requestPictureInPicture:`, `-scrubTo:error:`, `-seekTo:error:`, `-setBridge:`, `-setDelegate:`, `-setMute:error:`, `-setOwner:`, `-setPipController:`, `-setPosition:`, `-setVolume:error:`, `-skipAd:`, `-toggleCamera:`, `-toggleMicrophone:`

#### `ArcWebContentsMediaSessionPiPController` : NSObject  (6 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-initWithPiPController:`, `-nativePiPController`, `-sourceElementBounds`, `-videoView`

#### `ArcWebContentsNavigationController` : NSObject  (19 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-addObserver:`, `-goBack`, `-goForward`, `-goToBackForwardListItem:`, `-hash`, `-init:forWebContents:`, `-isEqual:`, `-load:initiatorOrigin:`, `-load:initiatorOrigin:transition:fromAddressBar:typedWithHttpScheme:`, `-nativeController`, `-observers`, `-owner`, `-reload`, `-reloadWithoutCache`, `-removeObserver:`, `-setObservers:`, `-setOwner:`

#### `ArcWebContentsPDFController` : NSObject  (9 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-availablePages:error:`, `-getAvailableTextOn:callback:error:`, `-getBookmarks:error:`, `-hasBookmarks:error:`, `-initWithWebContentsPDFController:`, `-visiblePages:error:`, `-web_contents_pdf_controller`

#### `ArcWebContentsThumbnailsGenerator` : NSObject  (13 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-addObserver:`, `-hash`, `-init:forWebContents:`, `-isEqual:`, `-observers`, `-owner`, `-removeObserver:`, `-requestThumbnail:`, `-setObservers:`, `-setOwner:`, `-thumbnailsGenerator`

#### `ArcWebDialog` : NSObject  (10 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accessibleTitle`, `-dialog`, `-initWithWebDialog:`, `-minimumSize`, `-preferredSize`, `-setDialog:`, `-title`, `-webContents`

#### `ArcWebLoginDialog` : NSObject  (11 methods)

`-.cxx_construct`, `-.cxx_destruct`, `-accept:with:`, `-authority`, `-cancel`, `-close`, `-dialog`, `-initWithWebLoginDialog:`, `-isProxyLogin`, `-isURLPotentiallyTrustworthy`, `-setDialog:`

