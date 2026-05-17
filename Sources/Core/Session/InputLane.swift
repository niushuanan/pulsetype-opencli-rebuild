import Foundation

enum InputLane: String {
    case directDictation

    var title: String {
        "普通听写"
    }

    var summary: String {
        "说话后由 ASR 转写，再交给 DeepSeek 整理，最后写入当前输入位置。"
    }
}
