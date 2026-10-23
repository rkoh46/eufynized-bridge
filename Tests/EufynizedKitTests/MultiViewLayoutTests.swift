import CoreGraphics
import Testing
@testable import EufynizedKit

@Suite struct MultiViewLayoutTests {
    @Test func fitAllUsesTheWholeWideWindow() {
        // 7 cameras in a maximized wide window: 3 columns (563pt tiles) beat 4 (500pt), and both beat
        // the old single thin strip (~240pt).
        let size = CGSize(width: 2000, height: 950)
        #expect(MultiViewLayout.bestColumns(count: 7, in: size) == 3)
        let frames = MultiViewLayout.auto.frames(count: 7, in: size, spacing: 4)
        #expect(frames.count == 7)
        #expect(frames[0].width > 550)
    }

    @Test func slotsStayInsideTheView() {
        let size = CGSize(width: 1280, height: 800)
        for layout in MultiViewLayout.allCases {
            for frame in layout.frames(count: 7, in: size, spacing: 4) {
                #expect(frame.minX >= -0.5 && frame.minY >= -0.5)
                #expect(frame.maxX <= size.width + 0.5 && frame.maxY <= size.height + 0.5, "\(layout)")
            }
        }
    }

    @Test func featuredSlotIsBiggest() {
        let frames = MultiViewLayout.focus1plus5.frames(count: 6, in: CGSize(width: 1600, height: 900), spacing: 4)
        #expect(frames.count == 6)
        #expect(frames[0].width > frames[1].width * 1.9)
    }

    @Test func slotsNeverOverlap() {
        for layout in MultiViewLayout.allCases {
            let frames = layout.frames(count: 9, in: CGSize(width: 1600, height: 900), spacing: 4)
            for i in frames.indices { for j in frames.indices where j > i {
                #expect(frames[i].intersection(frames[j]).width < 0.5 || frames[i].intersection(frames[j]).height < 0.5,
                        "\(layout) slots \(i) and \(j) overlap")
            }}
        }
    }
}
