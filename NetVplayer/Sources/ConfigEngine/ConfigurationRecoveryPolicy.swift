import Foundation
import Networking

/// Separates using an already saved configuration from retrying its remote refresh.
public enum ConfigurationRecoveryPolicy {
    public static func canRestoreCachedConfiguration(after error: Error) -> Bool {
        if case DecoderError.emptyData = error { return true }
        if case HTTPError.httpError(let status, _) = error {
            return status == 408 || (500...599).contains(status)
        }
        guard let code = urlErrorCode(error) else { return false }
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
             .secureConnectionFailed, .serverCertificateHasBadDate,
             .serverCertificateUntrusted, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected,
             .clientCertificateRequired:
            return true
        default:
            return false
        }
    }

    /// Returns the delay before the next background attempt; retryNumber starts at zero.
    /// Returning nil ends automatic retries while leaving saved sites available.
    public static func retryDelay(after error: Error, retryNumber: Int) -> Duration? {
        let delays: [Duration] = [.seconds(2), .seconds(5), .seconds(10)]
        guard isRetryableFailure(error), delays.indices.contains(retryNumber) else { return nil }
        return delays[retryNumber]
    }

    private static func isRetryableFailure(_ error: Error) -> Bool {
        if case DecoderError.emptyData = error { return true }
        if case HTTPError.httpError(let status, _) = error {
            return status == 408 || (500...599).contains(status)
        }
        guard let code = urlErrorCode(error) else { return false }
        switch code {
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost,
             .dnsLookupFailed, .notConnectedToInternet, .resourceUnavailable,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    private static func urlErrorCode(_ error: Error) -> URLError.Code? {
        let error = error as NSError
        guard error.domain == NSURLErrorDomain else { return nil }
        return URLError.Code(rawValue: error.code)
    }
}
