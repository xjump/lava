#ifndef _LEXPR_HXX
#define _LEXPR_HXX

#include <cstdint>
#include <string>
#include <vector>
#include <memory>

struct LExpr {
    enum Type {
        STR, HEX, DECIMAL, BINOP, FUNC, BLOCK, IF, CAST, INDEX
    } t;

    uint32_t value;
    std::string str;
    std::vector<std::shared_ptr<LExpr>> args;

    LExpr(Type t, uint32_t value, std::string str,
            std::initializer_list<LExpr> init_args)
        : t(t), value(value), str(str) {
        for (const LExpr &arg : init_args) {
            args.emplace_back(new LExpr(arg));
        }
    }

    LExpr(Type t, uint32_t value, std::string str,
            std::vector<LExpr> init_args)
        : t(t), value(value), str(str) {
        for (const LExpr &arg : init_args) {
            args.emplace_back(new LExpr(std::move(arg)));
        }
    }

    std::string render() const {
        std::stringstream os;
        os << *this;
        return os.str();
    }

    void infix(std::ostream &os, std::string begin, std::string sep, std::string end) const {
        auto it = args.cbegin();
        os << begin;
        for (; it != args.cend() - 1; it++) {
            os << **it << sep;
        }
        os << **it << end;
    }

    friend std::ostream &operator<<(std::ostream &os, const LExpr &expr) {
        if (expr.t == STR) {
            os << expr.str;
        } else if (expr.t == LExpr::HEX) {
            os << "0x" << std::hex << expr.value;
        } else if (expr.t == LExpr::DECIMAL) {
            os << std::dec << expr.value;
        } else if (expr.t == LExpr::BINOP) {
            expr.infix(os, "(", " " + expr.str + " ", ")");
        } else if (expr.t == LExpr::FUNC) {
            os << expr.str;
            expr.infix(os, "(", ", ", ")");
        } else if (expr.t == LExpr::BLOCK) {
            expr.infix(os, "({", "; ", ";})");
        } else if (expr.t == LExpr::IF) {
            os << "if (" << expr.str << ") ";
            expr.infix(os, "{\n", ";\n", ";\n}\n");
        } else if (expr.t == LExpr::CAST) {
            os << "((" << expr.str << ")" << *expr.args.at(0) << ")";
        } else if (expr.t == LExpr::INDEX) {
            os << *expr.args.at(0) << "[" << expr.value << "]";
        } else { assert(false && "Bad expr!"); }

        return os;
    }
};

// Binary operator.
LExpr LBinop(std::string op, LExpr left, LExpr right) {
    return LExpr(LExpr::BINOP, 0, op, { left, right });
}

LExpr LBinop(std::string op, std::vector<LExpr> args) {
    return LExpr(LExpr::BINOP, 0, op, std::move(args));
}

LExpr operator-(LExpr us, LExpr other) { return LBinop("-", us, other); }
LExpr operator+(LExpr us, LExpr other) { return LBinop("+", us, other); }
LExpr operator*(LExpr us, LExpr other) { return LBinop("*", us, other); }
LExpr operator==(LExpr us, LExpr other) { return LBinop("==", us, other); }
LExpr operator&&(LExpr us, LExpr other) { return LBinop("&&", us, other); }
LExpr operator||(LExpr us, LExpr other) { return LBinop("||", us, other); }
LExpr operator>>(LExpr us, LExpr other) { return LBinop(">>", us, other); }
LExpr operator<<(LExpr us, LExpr other) { return LBinop("<<", us, other); }
LExpr operator&(LExpr us, LExpr other) { return LBinop("&", us, other); }
LExpr operator|(LExpr us, LExpr other) { return LBinop("|", us, other); }
LExpr operator<(LExpr us, LExpr other) { return LBinop("<", us, other); }

LExpr LStr(std::string str) {
    return LExpr(LExpr::STR, 0, str, {});
}

LExpr LHex(uint32_t value) {
    return LExpr(LExpr::HEX, value, "", {});
}

LExpr LDecimal(uint32_t value) {
    return LExpr(LExpr::DECIMAL, value, "", {});
}

LExpr LBlock(std::initializer_list<LExpr> stmts) {
    return LExpr(LExpr::BLOCK, 0, "", stmts);
}

LExpr LFunc(std::string name, std::initializer_list<LExpr> args) {
    return LExpr(LExpr::FUNC, 0, name, args);
}

LExpr LIf(std::string cond, std::initializer_list<LExpr> stmts) {
    return LExpr(LExpr::IF, 0, cond, stmts);
}

LExpr LIf(std::string cond, std::vector<LExpr> stmts) {
    return LExpr(LExpr::IF, 0, cond, stmts);
}

LExpr LCast(std::string type, LExpr value) {
    return LExpr(LExpr::CAST, 0, type, { value });
}

LExpr LIndex(LExpr array, uint32_t index) {
    return LExpr(LExpr::INDEX, index, "", { array });
}

LExpr LavaGet(const Bug *bug) {
    return LFunc("lava_get", { LDecimal(bug->id) });
}

LExpr LavaSet(const Bug *bug, LExpr value) {
    return LFunc("lava_set", { LDecimal(bug->id), value });
}

template<typename UInt>
UInt BSwap(UInt x);

template<>
uint32_t BSwap<uint32_t>(uint32_t x) { return __builtin_bswap32(x); }
template<>
uint16_t BSwap<uint16_t>(uint16_t x) { return __builtin_bswap16(x); }

template<typename UInt>
LExpr MagicTest(UInt magic_value, const Bug *bug) {
    return LHex(magic_value) == LavaGet(bug) ||
        LHex(BSwap<UInt>(magic_value)) == LavaGet(bug);
}

LExpr traditionalAttack(const Bug *bug) {
    return LavaGet(bug) * MagicTest(bug->magic(), bug);
}

LExpr knobTriggerAttack(const Bug *bug) {
    LExpr lava_get_lower = LavaGet(bug) & LHex(0xffff);
    LExpr lava_get_upper = (LavaGet(bug) >> LDecimal(16)) & LHex(0xffff);
    // this is the magic value that will trigger the bug
    uint16_t magic_value = bug->magic() & 0xffff;
    uint16_t magic_value_bs = __builtin_bswap32(bug->magic() & 0xffff);

    return (lava_get_lower * MagicTest(magic_value, bug))
        + (lava_get_upper * MagicTest(magic_value_bs, bug));
}

LExpr RangeTest(uint32_t magic_value, uint32_t range_size, LExpr value) {
    return LHex(magic_value - range_size) < value &&
        value < LHex(magic_value + range_size);
}

template<uint32_t num_bits>
LExpr rangeStyleAttack(const Bug *bug) {
    return LavaGet(bug) * (RangeTest(bug->magic(), 1U << num_bits, LavaGet(bug)) ||
        RangeTest(__builtin_bswap32(bug->magic()), 1U << num_bits, LavaGet(bug)));
}

#endif