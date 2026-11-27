import Foundation
import VPhonePatchKit

/// Validate the native policy walk before applying restore-only admission.
/// The callback anchor survives the old force-PASS patch, so it is insufficient
/// without the entry, argument setup, policy loop and shared return paths.
enum RestoreTXMNativePrecheck {
    static func buildLabel(in data: Data) -> String {
        let marker = Data("TrustedExecutionMonitor".utf8)
        guard let start = data.range(of: marker)?.lowerBound else { return "unknown build" }
        let bytes = data[start ..< min(data.endIndex, start + 160)].prefix {
            (48 ... 57).contains($0) || (65 ... 90).contains($0) || (97 ... 122).contains($0)
                || [45, 46, 95].contains($0)
        }
        guard bytes.count > marker.count, bytes.count < 160, bytes.contains(45) else {
            return "unknown build"
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func validate(_ data: Data) throws {
        let disassembler = ARM64Disassembler()
        var candidates = 0
        for segment in MachOParser.parseSegments(from: data) where segment.name == "__TEXT_EXEC" {
            let code = disassembler.disassemble(in: data, at: Int(segment.fileOffset), count: Int(segment.fileSize / 4))
            for callback in code.indices.dropLast(3) {
                guard matches(code[callback], "mov", [.x(17)], 0x7e51),
                      matches(code[callback + 1], "blraa", [.x(8), .x(17)]),
                      matches(code[callback + 2], "tst", [.w(0)], 0xff00),
                      code[callback + 3].mnemonic == "b.ne",
                      let start = code[..<callback].lastIndex(where: { $0.mnemonic == "pacibsp" }),
                      let end = code[callback...].firstIndex(where: { $0.mnemonic == "retab" }) else { continue }
                let function = Array(code[start...end])
                guard isNative(function, callback: callback - start, code: code, data: data) else { continue }
                candidates += 1
            }
        }
        guard candidates == 1 else {
            throw PatcherError.patchSiteNotFound("restore TXM requires the original native policy pre-check")
        }
    }

    private static func isNative(_ f: [ARM64Instruction], callback c: Int,
                                 code: [ARM64Instruction], data: Data) -> Bool {
        guard f.count >= 24, c >= 18, c + 4 < f.count,
              f.allSatisfy({ $0.isDecoded && $0.size == 4 }),
              zip(f, f.dropFirst()).allSatisfy({ $1.address == $0.address + 4 }),
              let allocation = f[1].detail?.operands, allocation.count == 3,
              allocation[2].type == .immediate else { return false }
        let frame = allocation[2].imm
        guard frame >= 112, frame <= 4096, frame % 16 == 0,
              matches(f[1], "sub", [.sp, .sp], frame),
              matches(f[7], "add", [.x(29), .sp], frame - 16),
              matches(f[8], "mov", [.x(19), .x(1)]),
              matches(f[9], "mov", [.x(20), .x(0)]) else { return false }

        let saved: [[ARM64Register]] = [[.x(26), .x(25)], [.x(24), .x(23)],
                                       [.x(22), .x(21)], [.x(20), .x(19)], [.x(29), .x(30)]]
        let epilogue = f.count - 7
        for (n, registers) in saved.enumerated() {
            guard memory(f[n + 2], "stp", registers, .sp, Int32(frame - Int64(5 - n) * 16)) else { return false }
        }
        for (n, registers) in saved.reversed().enumerated() {
            guard memory(f[epilogue + n], "ldp", registers, .sp, Int32(frame - Int64(n + 1) * 16)) else { return false }
        }
        guard matches(f[epilogue + 5], "add", [.sp, .sp], frame),
              let scratch = f[10].detail?.operands.last, scratch.type == .memory,
              scratch.mem.disp >= 8, Int64(scratch.mem.disp) + 16 <= frame - 80,
              memory(f[10], "stp", [.xzr, .xzr], .sp, scratch.mem.disp),
              memory(f[11], "ldr", [.x(22)], .x(20), 0x40, postIndex: true),
              memory(f[12], "str", [.xzr], .sp, scratch.mem.disp - 8),
              memory(f[13], "ldr", [.x(8)], .x(22), 0x20),
              matches(f[14], "cbnz", [.x(8)], Int64(f[17].address)),
              memory(f[15], "ldr", [.x(8)], .x(22), 0x18),
              memory(f[17], "ldrb", [.w(23)], .x(22), 0x30),
              matches(f[18], "tst", [.w(23)], 1),
              memory(f[c - 3], "ldurb", [.w(0)], .x(24), -1),
              matches(f[c - 2], "mov", [.x(1), .x(20)]),
              matches(f[c - 1], "mov", [.x(2), .x(21)]) else { return false }

        let byAddress = Dictionary(uniqueKeysWithValues: f.enumerated().map { ($0.element.address, $0.offset) })
        guard let retry = branchIndex(f[c + 3], "b.ne", byAddress),
              retry == c + 10, retry + 12 == epilogue,
              matches(f[retry], "add", [.x(24), .x(24)], 2),
              matches(f[retry + 1], "subs", [.x(25), .x(25)], 1),
              let loop = branchIndex(f[retry + 2], "b.ne", byAddress),
              loop == 24, c == loop + 6,
              matches(f[loop - 1], "mov", [.w(25)], 3),
              memory(f[loop], "ldr", [.x(8)], .x(22), 0x20),
              matches(f[retry + 3], "mov", [.w(0)], 0x2990),
              matches(f[retry + 4], "movk", [.w(0)], 2, shift: 16),
              matches(f[retry + 5], "b", [], Int64(f[epilogue].address)) else { return false }

        // Account for the entire setup and callback span. An unchecked branch
        // here could skip the walk while leaving every later anchor intact.
        guard matches(f[19], "add", [.x(8), .sp], Int64(scratch.mem.disp)),
              matches(f[20], "csel", [.x(21), .x(8), .xzr]), f[20].detail?.conditionCode == .ne,
              let page = f[21].detail?.operands, page.count == 2,
              f[21].mnemonic == "adrp", page[0].type == .register, page[0].reg == .x(24),
              page[1].type == .immediate, page[1].imm >= 0,
              page[1].imm <= Int64(data.count), page[1].imm % 4096 == 0,
              let offset = f[22].detail?.operands.last, offset.type == .immediate,
              offset.imm >= 0, offset.imm < 4096,
              matches(f[22], "add", [.x(24), .x(24)], offset.imm),
              matches(f[loop + 1], "cbnz", [.x(8)], Int64(f[loop + 3].address)),
              memory(f[loop + 2], "ldr", [.x(8)], .x(22), 0x18),
              matches(f[c + 5], "add", [.x(0), .sp], Int64(scratch.mem.disp)),
              matches(f[c + 6], "add", [.x(1), .sp], Int64(scratch.mem.disp - 8)),
              memory(f[c + 8], "ldrb", [.w(8)], .sp, scratch.mem.disp - 8) else { return false }
        let table = page[1].imm + offset.imm
        // Native callback selectors 1/2/3 produce cache categories 9/8/7.
        guard table > 0, table + 5 <= Int64(data.count),
              Array(data[Int(table - 1)..<Int(table + 5)]) == [1, 9, 2, 8, 3, 7],
              let call = f[c + 7].detail?.operands, call.count == 1,
              f[c + 7].mnemonic == "bl", call[0].type == .immediate, call[0].imm >= 0,
              let reader = code.firstIndex(where: { $0.address == UInt64(call[0].imm) }),
              reader + 2 < code.count, code[reader].mnemonic == "bti",
              code[reader + 1].address == code[reader].address + 4,
              code[reader + 2].address == code[reader].address + 8,
              memory(code[reader + 1], "ldr", [.x(8)], .x(0), 0),
              memory(code[reader + 2], "ldp", [.x(9), .x(8)], .x(8), 0x10) else { return false }

        let success = retry + 6
        guard memory(f[success], "ldrb", [.w(8)], .x(24), 0),
              memory(f[success + 1], "strb", [.w(8)], .x(19), 0),
              matches(f[success + 2], "mov", [.w(0)], 0x90),
              matches(f[success + 3], "b", [], Int64(f[epilogue].address)),
              matches(f[16], "cbz", [.x(8)], Int64(f[success + 4].address)),
              matches(f[success + 4], "mov", [.w(0)], 0x2890),
              matches(f[success + 5], "movk", [.w(0)], 1, shift: 16),
              bitBranch(f[c + 4], .w(23), 0, f[success].address),
              bitBranch(f[c + 9], .w(8), 1, f[success].address) else { return false }
        return true
    }

    private static func matches(_ i: ARM64Instruction, _ mnemonic: String,
                                _ registers: [ARM64Register], _ immediate: Int64? = nil,
                                shift: UInt32 = 0) -> Bool {
        guard i.mnemonic == mnemonic, let operands = i.detail?.operands,
              operands.count == registers.count + (immediate == nil ? 0 : 1),
              zip(operands, registers).allSatisfy({ $0.type == .register && $0.reg == $1 }) else { return false }
        guard let immediate else { return true }
        let operand = operands[registers.count]
        return operand.type == .immediate && operand.imm == immediate && operand.shift.amount == shift
            && (shift == 0 || operand.shift.type == .lsl)
    }

    private static func memory(_ i: ARM64Instruction, _ mnemonic: String,
                               _ registers: [ARM64Register], _ base: ARM64Register,
                               _ displacement: Int32, postIndex: Bool = false) -> Bool {
        guard i.mnemonic == mnemonic, let detail = i.detail,
              detail.operands.count == registers.count + 1,
              zip(detail.operands, registers).allSatisfy({ $0.type == .register && $0.reg == $1 }),
              detail.postIndex == postIndex, detail.writeback == postIndex else { return false }
        let operand = detail.operands[registers.count]
        guard operand.type == .memory, operand.mem.base == base, operand.mem.index == .invalid,
              operand.mem.disp == displacement else { return false }
        return true
    }

    private static func branchIndex(_ i: ARM64Instruction, _ mnemonic: String,
                                    _ byAddress: [UInt64: Int]) -> Int? {
        guard i.mnemonic == mnemonic, let operands = i.detail?.operands, operands.count == 1,
              operands[0].type == .immediate, operands[0].imm >= 0 else { return nil }
        return byAddress[UInt64(operands[0].imm)]
    }

    private static func bitBranch(_ i: ARM64Instruction, _ register: ARM64Register,
                                  _ bit: Int64, _ destination: UInt64) -> Bool {
        guard i.mnemonic == "tbz", let operands = i.detail?.operands, operands.count == 3 else { return false }
        return operands[0].type == .register && operands[0].reg == register
            && operands[1].type == .immediate && operands[1].imm == bit
            && operands[2].type == .immediate && operands[2].imm == Int64(destination)
    }
}
