//  Traceroute.swift
//  Traceroute cho iOS, không cần entitlement, không cần jailbreak.
//
//  Cách làm:
//    - Gửi probe bằng UDP socket tới port 33434+ttl, đặt IP_TTL tăng dần.
//    - Router nào hết TTL sẽ trả về ICMP Time Exceeded (type 11).
//    - Một socket ICMP RIÊNG, chỉ đọc không gửi, nhận các gói đó.
//
//  Vì sao không dùng ICMP Echo + IP_TTL như trên Linux: setsockopt(IP_TTL)
//  trên SOCK_DGRAM ICMP của Darwin hoạt động không nhất quán, và việc match
//  reply với probe phải dựa vào payload lồng bên trong — dễ sai. Dùng UDP thì
//  port đích chính là mã số của probe, match chuẩn xác.

import Foundation

enum TracerouteError: Error {
    case resolveFailed
    case socketFailed(String)
}

struct TraceHop {
    let ttl: Int
    let address: String?
    let rttMs: Double?
    let isDestination: Bool

    var asDictionary: [String: Any] {
        var dict: [String: Any] = ["ttl": ttl, "isDestination": isDestination]
        if let address = address { dict["address"] = address }
        if let rttMs = rttMs { dict["rttMs"] = rttMs }
        return dict
    }
}

final class Traceroute {

    private let host: String
    private let maxHops: Int
    private let perHopTimeout: TimeInterval

    /// Dải port traceroute dùng theo thông lệ từ thời BSD — chọn dải cao và
    /// hiếm dùng để gần như chắc chắn không có service nào đang nghe, nhờ vậy
    /// đích sẽ trả ICMP Port Unreachable thay vì nuốt gói.
    private let basePort: UInt16 = 33434

    init(host: String, maxHops: Int = 30, perHopTimeout: TimeInterval = 1.5) {
        self.host = host
        self.maxHops = max(1, min(maxHops, 64))
        self.perHopTimeout = perHopTimeout
    }

    func run() throws -> [TraceHop] {
        guard var destination = Traceroute.resolveIPv4(host) else {
            throw TracerouteError.resolveFailed
        }
        let destinationIP = Traceroute.ipString(destination.sin_addr)

        // Socket ICMP thụ động: chỉ đọc, không bao giờ gửi từ nó.
        let icmpFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP)
        guard icmpFD >= 0 else {
            throw TracerouteError.socketFailed("icmp socket errno \(errno)")
        }
        defer { close(icmpFD) }

        var tv = timeval(
            tv_sec: Int(perHopTimeout),
            tv_usec: Int32((perHopTimeout - floor(perHopTimeout)) * 1_000_000)
        )
        setsockopt(icmpFD, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var hops: [TraceHop] = []

        for ttl in 1...maxHops {
            let probePort = basePort &+ UInt16(ttl)
            destination.sin_port = probePort.bigEndian

            let startedAt = CFAbsoluteTimeGetCurrent()
            guard sendProbe(to: destination, ttl: ttl) else {
                hops.append(TraceHop(ttl: ttl, address: nil, rttMs: nil, isDestination: false))
                continue
            }

            let hop = awaitReply(
                icmpFD: icmpFD,
                ttl: ttl,
                probePort: probePort,
                startedAt: startedAt,
                destinationIP: destinationIP
            )
            hops.append(hop)

            if hop.isDestination { break }
        }

        return hops
    }

    // MARK: - Gửi probe

    private func sendProbe(to destination: sockaddr_in, ttl: Int) -> Bool {
        let udpFD = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard udpFD >= 0 else { return false }
        defer { close(udpFD) }

        var ttlValue = Int32(ttl)
        guard setsockopt(udpFD, IPPROTO_IP, IP_TTL, &ttlValue, socklen_t(MemoryLayout<Int32>.size)) == 0
        else { return false }

        let payload = [UInt8](repeating: 0x40, count: 32)
        var target = destination

        let sent = withUnsafePointer(to: &target) { pointer -> Int in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                sendto(udpFD, payload, payload.count, 0, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return sent > 0
    }

    // MARK: - Nhận ICMP

    private func awaitReply(
        icmpFD: Int32,
        ttl: Int,
        probePort: UInt16,
        startedAt: CFAbsoluteTime,
        destinationIP: String
    ) -> TraceHop {
        let deadline = startedAt + perHopTimeout

        // Socket ICMP nhận MỌI gói ICMP tới máy, kể cả của app khác đang ping.
        // Nên phải lọc: chỉ nhận gói mà probe port lồng bên trong khớp với
        // probe của chính vòng lặp này.
        while CFAbsoluteTimeGetCurrent() < deadline {
            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            var buffer = [UInt8](repeating: 0, count: 1024)

            let received = withUnsafeMutablePointer(to: &from) { pointer -> Int in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                    recvfrom(icmpFD, &buffer, buffer.count, 0, sa, &fromLength)
                }
            }

            if received <= 0 { break } // timeout hoặc lỗi

            guard let parsed = Traceroute.parseICMP(buffer: buffer, length: received),
                  parsed.probePort == probePort
            else { continue }

            let rtt = (CFAbsoluteTimeGetCurrent() - startedAt) * 1000
            let source = Traceroute.ipString(from.sin_addr)

            return TraceHop(
                ttl: ttl,
                address: source,
                rttMs: rtt,
                // Port Unreachable = đích đã nhận gói nhưng không có ai nghe
                // port đó → đã tới nơi.
                isDestination: parsed.isUnreachable || source == destinationIP
            )
        }

        return TraceHop(ttl: ttl, address: nil, rttMs: nil, isDestination: false)
    }

    // MARK: - Bóc gói

    private struct ParsedICMP {
        let isUnreachable: Bool
        let probePort: UInt16
    }

    /// Gói nhận được có dạng:
    ///   [IP header][ICMP header 8B][IP header gốc][8 byte đầu của UDP gốc]
    /// Port đích trong UDP header gốc chính là mã số probe.
    private static func parseICMP(buffer: [UInt8], length: Int) -> ParsedICMP? {
        guard length > 0 else { return nil }

        let ipHeaderLength = Int(buffer[0] & 0x0F) * 4
        guard ipHeaderLength >= 20, length >= ipHeaderLength + 8 else { return nil }

        let icmpType = buffer[ipHeaderLength]
        // 11 = Time Exceeded, 3 = Destination Unreachable
        guard icmpType == 11 || icmpType == 3 else { return nil }

        let innerIPOffset = ipHeaderLength + 8
        guard length >= innerIPOffset + 20 else { return nil }

        let innerIPHeaderLength = Int(buffer[innerIPOffset] & 0x0F) * 4
        let udpOffset = innerIPOffset + innerIPHeaderLength
        guard length >= udpOffset + 4 else { return nil }

        let destinationPort = (UInt16(buffer[udpOffset + 2]) << 8) | UInt16(buffer[udpOffset + 3])
        return ParsedICMP(isUnreachable: icmpType == 3, probePort: destinationPort)
    }

    // MARK: - Tiện ích

    private static func resolveIPv4(_ host: String) -> sockaddr_in? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        hints.ai_protocol = IPPROTO_UDP

        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &info) == 0, let first = info else { return nil }
        defer { freeaddrinfo(info) }

        guard let addressPointer = first.pointee.ai_addr else { return nil }
        return addressPointer.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
    }

    private static func ipString(_ address: in_addr) -> String {
        var mutable = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        inet_ntop(AF_INET, &mutable, &buffer, socklen_t(INET_ADDRSTRLEN))
        return String(cString: buffer)
    }
}
