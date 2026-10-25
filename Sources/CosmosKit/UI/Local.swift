import SwiftUI

/// A stand-in for `@State`.
///
/// With only the Command Line Tools installed, the `SwiftUIMacros` plugin that expands `@State` in the current SDK is
/// missing, so `@State` won't compile. The underlying `State<Value>` struct is a plain `DynamicProperty`; wrapping it
/// here gives the same behaviour (storage owned by the view's identity, `$value` projects a `Binding`).
@propertyWrapper
struct Local<Value>: DynamicProperty {
    private var state: State<Value>

    init(wrappedValue: Value) { state = State(initialValue: wrappedValue) }

    var wrappedValue: Value {
        get { state.wrappedValue }
        nonmutating set { state.wrappedValue = newValue }
    }

    var projectedValue: Binding<Value> { state.projectedValue }
}
