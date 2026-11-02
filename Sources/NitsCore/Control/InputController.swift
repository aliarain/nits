import Foundation

public final class InputController: @unchecked Sendable {
    private let ddc: DDCEngine

    public init(ddc: DDCEngine) {
        self.ddc = ddc
    }

    /// The monitor's advertised input list when capabilities are readable; otherwise
    /// the MCCS/industry-standard set.
    public func options(for display: DisplaySnapshot) async -> [InputOption] {
        let capabilities = await ddc.capabilities(display: display)
        return InputSource.options(from: capabilities)
    }

    /// Never cached: input changes outside Nits (the monitor's own OSD, another computer).
    public func currentInput(for display: DisplaySnapshot) async -> UInt16? {
        guard let value = await ddc.read(
            display: display,
            code: InputSource.vcp,
            useCache: false
        ) else { return nil }
        return InputSource.current(fromReply: value.current)
    }

    @discardableResult
    public func setInput(_ value: UInt16, for display: DisplaySnapshot) async -> Bool {
        await ddc.write(display: display, code: InputSource.vcp, value: value)
    }
}
