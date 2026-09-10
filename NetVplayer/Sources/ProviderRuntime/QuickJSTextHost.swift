import Foundation
import ProviderSDK

struct QuickJSTextHost: @unchecked Sendable {
    func handle(_ request: QuickJSHostControl) async -> QuickJSHostResponse {
        guard request.capability == "text" else {
            return failure(
                requestID: request.requestID,
                code: "unsupported_host_request",
                message: "Unsupported QuickJS text request"
            )
        }

        guard let input = string(request.options?["value"]) else {
            return failure(
                requestID: request.requestID,
                code: "invalid_value",
                message: "Text value is invalid"
            )
        }

        let transform: StringTransform
        switch request.operation {
        case "s2t":
            transform = StringTransform("Simplified-Traditional")
        case "t2s":
            transform = StringTransform("Traditional-Simplified")
        default:
            return failure(
                requestID: request.requestID,
                code: "unsupported_operation",
                message: "QuickJS text operation is unsupported"
            )
        }

        let value = input.applyingTransform(transform, reverse: false) ?? input
        return QuickJSHostResponse(
            requestID: request.requestID,
            ok: true,
            result: .object(["value": .string(value)])
        )
    }

    private func string(_ value: ProviderJSONValue?) -> String? {
        guard case .string(let value) = value else { return nil }
        return value
    }

    private func failure(requestID: String, code: String, message: String) -> QuickJSHostResponse {
        QuickJSHostResponse(
            requestID: requestID,
            ok: false,
            error: ProviderErrorPayload(code: code, message: message)
        )
    }
}
