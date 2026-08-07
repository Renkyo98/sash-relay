#include "pch.h"
#include "battle_snapshot_parser.h"
#include "item_snapshot_parser.h"
#include "character_snapshot_parser.h"
#include "dialog_snapshot_parser.h"
#include "skill_team_snapshot_parser.h"
#include "mail_history_snapshot_parser.h"
#include "shop_chat_map_snapshot_parser.h"
#include "client_runtime_diagnostics.h"
#include "client_control.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <limits>
#include <memory>
#include <process.h>
#include <sstream>
#include <tuple>
#include <utility>

namespace sash::runtime_diagnostics
{
namespace
{
constexpr std::size_t kFloorNameBytes = 25u;
constexpr std::size_t kPetArrayBytes = 0x3958u;
constexpr std::size_t kPetStride = 0xB78u;
constexpr std::size_t kPetSkillArrayBytes = 0xE7Eu;
constexpr std::size_t kPetSkillRowStride = 0x2E6u;
constexpr std::size_t kPetSkillStride = 0x6Au;
constexpr std::size_t kPetEquipOffset = 0x7Cu;
constexpr std::size_t kPetEquipStride = 0x17Cu;
constexpr unsigned int kPetReadAttempts = 3u;
constexpr unsigned int kBattleReadAttempts = 3u;
constexpr unsigned int kItemReadAttempts = 3u;
constexpr unsigned int kCharacterReadAttempts = 3u;
constexpr unsigned int kDialogReadAttempts = 3u;
constexpr unsigned int kSkillTeamReadAttempts = 3u;
constexpr unsigned int kMailHistoryReadAttempts = 3u;
constexpr DWORD kReadOnlyPollMilliseconds = 500u;
constexpr DWORD kSpeedPollMilliseconds = 50u;
constexpr DWORD kClient05SnapshotReadyRetryMilliseconds = 50u;
constexpr ULONGLONG kClient05SnapshotReadyBudgetMilliseconds = 30000u;
constexpr ULONGLONG kSpeedMeasurementMilliseconds = 10000u;
constexpr UINT kProcIdPassword = 1u;
constexpr UINT kProcGame = 9u;
constexpr UINT kProcBattle = 10u;
constexpr std::uint32_t kLoginAccountBufferRva = 0x0B8D5D80u;
constexpr std::uint32_t kLoginAccountCountRva = 0x0B8D5E87u;
constexpr std::uint32_t kLoginAccountCursorRva = 0x0B8D5E89u;
constexpr std::uint32_t kLoginPasswordBufferRva = 0x0B8D5EA8u;
constexpr std::uint32_t kLoginPasswordCountRva = 0x0B8D5FAFu;
constexpr std::uint32_t kLoginPasswordCursorRva = 0x0B8D5FB1u;
constexpr std::uint32_t kPcLandedGroupRva = 0x0B8DD748u;
constexpr std::uint32_t kPcLandedSubserverRva = 0x0B8DD750u;
constexpr std::uint32_t kPcLandedCharacterRva = 0x0B8DD754u;
constexpr std::uint32_t kNewAutoLoginEnableRva = 0x0B8DD800u;
constexpr LONG kLoginControlCount = 10L;

using Snapshot = client05_readonly::Snapshot;

struct MonitorContext
{
	HMODULE module = nullptr;
	std::uint32_t imageSize = 0u;
	client_bindings::ResolvedAddresses addresses{};
	std::atomic_bool* bindingValidated = nullptr;
	std::atomic_int* stopReason = nullptr;
	client05_readonly::Channel* channel = nullptr;
	HANDLE ownerProcess = nullptr;
	std::wstring logPath;
	LONG lastSpeedCommandSequence = 0L;
	LONG lastLoginCommandSequence = 0L;
	LONG activeSpeedCommandSequence = 0L;
	client05_readonly::SpeedMode activeSpeedMode = client05_readonly::SpeedMode::normal;
	DWORD originalSystemTime = 0u;
	DWORD appliedSystemTime = 0u;
	DWORD surfaceDateBefore = 0u;
	ULONGLONG measurementDeadline = 0u;
	bool originalCaptured = false;
	bool speedChanged = false;
	bool measurementActive = false;

	~MonitorContext()
	{
		if (ownerProcess != nullptr)
			CloseHandle(ownerProcess);
	}
};

bool checkedAdd(std::uintptr_t value, std::size_t amount, std::uintptr_t& result) noexcept
{
	if (amount > (std::numeric_limits<std::uintptr_t>::max)() - value)
		return false;
	result = value + amount;
	return true;
}

bool isReadableClientRange(
	HMODULE module,
	const void* address,
	std::size_t size) noexcept
{
	if (module == nullptr || address == nullptr || size == 0u)
		return false;

	const auto start = reinterpret_cast<std::uintptr_t>(address);
	std::uintptr_t end = 0u;
	if (!checkedAdd(start, size, end))
		return false;

	std::uintptr_t cursor = start;
	while (cursor < end)
	{
		MEMORY_BASIC_INFORMATION memory{};
		if (VirtualQuery(reinterpret_cast<const void*>(cursor), &memory, sizeof(memory)) == 0u ||
			memory.State != MEM_COMMIT || memory.AllocationBase != module ||
			(memory.Protect & (PAGE_NOACCESS | PAGE_GUARD)) != 0u)
		{
			return false;
		}

		const DWORD protection = memory.Protect & 0xFFu;
		if (protection != PAGE_READONLY && protection != PAGE_READWRITE &&
			protection != PAGE_WRITECOPY && protection != PAGE_EXECUTE_READ &&
			protection != PAGE_EXECUTE_READWRITE && protection != PAGE_EXECUTE_WRITECOPY)
		{
			return false;
		}

		std::uintptr_t regionEnd = 0u;
		if (!checkedAdd(reinterpret_cast<std::uintptr_t>(memory.BaseAddress), memory.RegionSize, regionEnd) ||
			regionEnd <= cursor)
		{
			return false;
		}
		cursor = (std::min)(regionEnd, end);
	}
	return true;
}

bool isWritableClientRange(
	HMODULE module,
	void* address,
	std::size_t size) noexcept
{
	if (module == nullptr || address == nullptr || size == 0u)
		return false;
	const auto start = reinterpret_cast<std::uintptr_t>(address);
	std::uintptr_t end = 0u;
	if (!checkedAdd(start, size, end))
		return false;

	std::uintptr_t cursor = start;
	while (cursor < end)
	{
		MEMORY_BASIC_INFORMATION memory{};
		if (VirtualQuery(reinterpret_cast<const void*>(cursor), &memory, sizeof(memory)) == 0u ||
			memory.State != MEM_COMMIT || memory.AllocationBase != module ||
			(memory.Protect & (PAGE_NOACCESS | PAGE_GUARD)) != 0u)
		{
			return false;
		}
		const DWORD protection = memory.Protect & 0xFFu;
		if (protection != PAGE_READWRITE && protection != PAGE_WRITECOPY)
			return false;
		std::uintptr_t regionEnd = 0u;
		if (!checkedAdd(reinterpret_cast<std::uintptr_t>(memory.BaseAddress), memory.RegionSize, regionEnd) ||
			regionEnd <= cursor)
		{
			return false;
		}
		cursor = (std::min)(regionEnd, end);
	}
	return true;
}

// Keep SEH in a function with no C++ objects that require unwinding.
bool guardedCopy(const void* source, void* destination, std::size_t size) noexcept
{
	__try
	{
		std::memcpy(destination, source, size);
		return true;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return false;
	}
}

// This is the only Client-memory write used by the Client 05 speed slice.
// The address is a validated, aligned SystemTime DWORD in writable data.
bool guardedWriteSystemTime(HMODULE module, std::uintptr_t address, DWORD value) noexcept
{
#if CLIENT05_SPEED_CONTROL
	auto* destination = reinterpret_cast<volatile LONG*>(address);
	if (address % alignof(DWORD) != 0u ||
		!isWritableClientRange(module, const_cast<LONG*>(destination), sizeof(DWORD)))
		return false;
	__try
	{
		InterlockedExchange(destination, static_cast<LONG>(value));
		return true;
	}
	__except (EXCEPTION_EXECUTE_HANDLER)
	{
		return false;
	}
#else
	(void)module;
	(void)address;
	(void)value;
	return false;
#endif
}

bool readClientDword(
	HMODULE module,
	std::uintptr_t address,
	DWORD& value) noexcept
{
	const auto* source = reinterpret_cast<const void*>(address);
	return address % alignof(DWORD) == 0u &&
		isReadableClientRange(module, source, sizeof(value)) &&
		guardedCopy(source, &value, sizeof(value));
}

bool loginTargetAddress(
	const MonitorContext& context,
	std::uint32_t rva,
	std::size_t size,
	std::uintptr_t& address) noexcept
{
	if (context.module == nullptr || size == 0u || rva >= context.imageSize ||
		size > static_cast<std::size_t>(context.imageSize - rva))
	{
		return false;
	}
	return checkedAdd(reinterpret_cast<std::uintptr_t>(context.module), rva, address);
}

bool isAuthorizedLoginField(std::uint32_t rva, std::size_t size) noexcept
{
	switch (rva)
	{
	case kLoginAccountBufferRva:
	case kLoginPasswordBufferRva:
		return size == client05_readonly::kLoginCredentialBytes;
	case kLoginAccountCountRva:
	case kLoginAccountCursorRva:
	case kLoginPasswordCountRva:
	case kLoginPasswordCursorRva:
		return size == sizeof(BYTE);
	case kPcLandedGroupRva:
	case kPcLandedSubserverRva:
	case kPcLandedCharacterRva:
	case kNewAutoLoginEnableRva:
		return size == sizeof(DWORD);
	default:
		return false;
	}
}

bool validateLoginField(
	const MonitorContext& context,
	std::uint32_t rva,
	std::size_t size) noexcept
{
	std::uintptr_t address = 0u;
	return isAuthorizedLoginField(rva, size) &&
		loginTargetAddress(context, rva, size, address) &&
		isReadableClientRange(context.module, reinterpret_cast<const void*>(address), size) &&
		isWritableClientRange(context.module, reinterpret_cast<void*>(address), size) &&
		(size != sizeof(DWORD) || address % alignof(DWORD) == 0u);
}

bool guardedWriteLoginField(
	const MonitorContext& context,
	std::uint32_t rva,
	const void* source,
	std::size_t size) noexcept
{
#if CLIENT05_AUTO_LOGIN
	std::uintptr_t address = 0u;
	if (source == nullptr || !validateLoginField(context, rva, size) ||
		!loginTargetAddress(context, rva, size, address))
	{
		return false;
	}
	if (size == sizeof(DWORD))
	{
		DWORD value = 0u;
		if (!guardedCopy(source, &value, sizeof(value)))
			return false;
		auto* destination = reinterpret_cast<volatile LONG*>(address);
		__try
		{
			InterlockedExchange(destination, static_cast<LONG>(value));
			return true;
		}
		__except (EXCEPTION_EXECUTE_HANDLER)
		{
			return false;
		}
	}
	return guardedCopy(source, reinterpret_cast<void*>(address), size);
#else
	(void)context;
	(void)rva;
	(void)source;
	(void)size;
	return false;
#endif
}

bool verifyLoginField(
	const MonitorContext& context,
	std::uint32_t rva,
	const void* expected,
	std::size_t size) noexcept
{
	if (expected == nullptr || size > client05_readonly::kLoginCredentialBytes)
		return false;
	std::uintptr_t address = 0u;
	std::array<unsigned char, client05_readonly::kLoginCredentialBytes> actual{};
	return validateLoginField(context, rva, size) &&
		loginTargetAddress(context, rva, size, address) &&
		guardedCopy(reinterpret_cast<const void*>(address), actual.data(), size) &&
		std::memcmp(actual.data(), expected, size) == 0;
}

struct FieldRead
{
	const wchar_t* name;
	std::uintptr_t address;
	void* destination;
	std::size_t size;
};

struct PetStateCoreSource
{
	std::int16_t battlePetNo;
	std::array<std::int16_t, client05_readonly::kPetSlots> selectPetNo;
	std::int16_t mailPetNo;
	std::int16_t standbyPet;
};

static_assert(sizeof(PetStateCoreSource) == 16u);

template<std::size_t Size, typename Value>
bool rawValue(
	const std::array<unsigned char, Size>& source,
	std::size_t offset,
	Value& value) noexcept
{
	if (offset > source.size() || sizeof(value) > source.size() - offset)
		return false;
	std::memcpy(&value, source.data() + offset, sizeof(value));
	return true;
}

template<std::size_t Capacity>
void cp949ToUtf16(
	const unsigned char* source,
	std::size_t sourceBytes,
	std::array<wchar_t, Capacity>& destination) noexcept
{
	destination.fill(L'\0');
	if (source == nullptr || sourceBytes == 0u || Capacity < 2u)
		return;
	const auto* begin = reinterpret_cast<const char*>(source);
	const auto* end = std::find(begin, begin + sourceBytes, '\0');
	const auto length = static_cast<int>(end - begin);
	if (length <= 0)
		return;
	const int required = MultiByteToWideChar(949u, 0, begin, length, nullptr, 0);
	if (required <= 0 || static_cast<std::size_t>(required) >= destination.size())
		return;
	if (MultiByteToWideChar(949u, 0, begin, length, destination.data(), required) != required)
		destination.fill(L'\0');
}

std::int16_t normalizedPetIndex(std::int16_t value) noexcept
{
	return value >= 0 && value < static_cast<std::int16_t>(client05_readonly::kPetSlots)
		? value
		: static_cast<std::int16_t>(-1);
}

std::int32_t normalizedPetIndex(std::int32_t value) noexcept
{
	return value >= 0 && value < static_cast<std::int32_t>(client05_readonly::kPetSlots)
		? value
		: -1;
}

bool readPetSources(
	HMODULE module,
	const client_bindings::ResolvedAddresses& addresses,
	std::array<unsigned char, kPetArrayBytes>& pet,
	std::array<unsigned char, kPetSkillArrayBytes>& petSkill,
	PetStateCoreSource& petState,
	std::int32_t& ridePetNo,
	const wchar_t*& failedField) noexcept
{
	struct SourceRead
	{
		const wchar_t* name;
		std::uintptr_t address;
		void* destination;
		std::size_t size;
	};
	const std::array<SourceRead, 4u> sources{
		SourceRead{ L"pet[5]", addresses.pet, pet.data(), pet.size() },
		SourceRead{ L"petSkill[5][7]", addresses.petSkill, petSkill.data(), petSkill.size() },
		SourceRead{ L"PC.petStateCore", addresses.petStateCore, &petState, sizeof(petState) },
		SourceRead{ L"PC.ridePetNo", addresses.ridePetNo, &ridePetNo, sizeof(ridePetNo) },
	};
	for (const auto& source : sources)
	{
		const auto* address = reinterpret_cast<const void*>(source.address);
		if (!isReadableClientRange(module, address, source.size) ||
			!guardedCopy(address, source.destination, source.size))
		{
			failedField = source.name;
			return false;
		}
	}
	return true;
}

bool populatePetBlock(
	const std::array<unsigned char, kPetArrayBytes>& petSource,
	const std::array<unsigned char, kPetSkillArrayBytes>& skillSource,
	const PetStateCoreSource& stateSource,
	std::int32_t ridePetNo,
	client05_readonly::PetBlockSnapshot& block) noexcept
{
	block = {};
	block.battlePetNo = normalizedPetIndex(stateSource.battlePetNo);
	block.selectPetNo = stateSource.selectPetNo;
	block.mailPetNo = normalizedPetIndex(stateSource.mailPetNo);
	block.standbyPet = stateSource.standbyPet;
	block.ridePetNo = normalizedPetIndex(ridePetNo);

	for (std::size_t petIndex = 0u; petIndex < client05_readonly::kPetSlots; ++petIndex)
	{
		const std::size_t petBase = petIndex * kPetStride;
		std::int16_t useFlag = 0;
		if (!rawValue(petSource, petBase + 0x76u, useFlag))
			return false;
		if (useFlag == 0)
			continue;

		auto& pet = block.pet[petIndex];
		pet.useFlag = useFlag;
		pet.occupied = 1u;
		++block.petCount;
		if (!rawValue(petSource, petBase + 0x08u, pet.hp) ||
			!rawValue(petSource, petBase + 0x0Cu, pet.maxHp) ||
			!rawValue(petSource, petBase + 0x10u, pet.mp) ||
			!rawValue(petSource, petBase + 0x20u, pet.level) ||
			!rawValue(petSource, petBase + 0x24u, pet.attack) ||
			!rawValue(petSource, petBase + 0x28u, pet.defense) ||
			!rawValue(petSource, petBase + 0x2Cu, pet.agility) ||
			!rawValue(petSource, petBase + 0x30u, pet.loyalty) ||
			!rawValue(petSource, petBase + 0x34u, pet.earth) ||
			!rawValue(petSource, petBase + 0x38u, pet.water) ||
			!rawValue(petSource, petBase + 0x3Cu, pet.fire) ||
			!rawValue(petSource, petBase + 0x40u, pet.wind) ||
			!rawValue(petSource, petBase + 0x44u, pet.maxSkill) ||
			!rawValue(petSource, petBase + 0x48u, pet.turn) ||
			!rawValue(petSource, petBase + 0x4Cu, pet.fusion) ||
			!rawValue(petSource, petBase + 0x50u, pet.status) ||
			!rawValue(petSource, petBase + 0x78u, pet.changeNameFlag))
		{
			return false;
		}
		cp949ToUtf16(petSource.data() + petBase + 0x54u, 17u, pet.name);
		cp949ToUtf16(petSource.data() + petBase + 0x65u, 17u, pet.freeName);

		pet.displayState = block.selectPetNo[petIndex] > 0
			? client05_readonly::PetDisplayState::selected
			: client05_readonly::PetDisplayState::rest;
		if (block.battlePetNo == static_cast<std::int16_t>(petIndex))
			pet.displayState = client05_readonly::PetDisplayState::battle;
		if (block.ridePetNo == static_cast<std::int32_t>(petIndex))
			pet.displayState = client05_readonly::PetDisplayState::ride;
		if (block.mailPetNo == static_cast<std::int16_t>(petIndex))
			pet.displayState = client05_readonly::PetDisplayState::mail;

		for (std::size_t skillIndex = 0u;
			skillIndex < client05_readonly::kPetSkillSlots;
			++skillIndex)
		{
			const std::size_t skillBase =
				petIndex * kPetSkillRowStride + skillIndex * kPetSkillStride;
			std::int16_t skillUseFlag = 0;
			if (!rawValue(skillSource, skillBase, skillUseFlag))
				return false;
			if (skillUseFlag == 0)
				continue;
			auto& skill = pet.skills[skillIndex];
			skill.useFlag = skillUseFlag;
			skill.occupied = 1u;
			if (!rawValue(skillSource, skillBase + 0x02u, skill.skillId) ||
				!rawValue(skillSource, skillBase + 0x04u, skill.field) ||
				!rawValue(skillSource, skillBase + 0x06u, skill.target))
			{
				return false;
			}
			cp949ToUtf16(skillSource.data() + skillBase + 0x08u, 25u, skill.name);
			cp949ToUtf16(skillSource.data() + skillBase + 0x21u, 73u, skill.memo);
		}

		for (std::size_t equipIndex = 0u;
			equipIndex < client05_readonly::kPetEquipSlots;
			++equipIndex)
		{
			const std::size_t equipBase =
				petBase + kPetEquipOffset + equipIndex * kPetEquipStride;
			std::int16_t equipUseFlag = 0;
			if (!rawValue(petSource, equipBase + 0xDCu, equipUseFlag))
				return false;
			if (equipUseFlag <= 0)
				continue;
			auto& equipment = pet.equipment[equipIndex];
			equipment.useFlag = equipUseFlag;
			equipment.occupied = 1u;
			if (!rawValue(petSource, equipBase + 0x000u, equipment.color) ||
				!rawValue(petSource, equipBase + 0x004u, equipment.modelId) ||
				!rawValue(petSource, equipBase + 0x008u, equipment.level) ||
				!rawValue(petSource, equipBase + 0x00Cu, equipment.stack) ||
				!rawValue(petSource, equipBase + 0x0DEu, equipment.field) ||
				!rawValue(petSource, equipBase + 0x0E0u, equipment.target) ||
				!rawValue(petSource, equipBase + 0x0E2u, equipment.deadTargetFlag) ||
				!rawValue(petSource, equipBase + 0x0E4u, equipment.sendFlag) ||
				!rawValue(petSource, equipBase + 0x179u, equipment.type))
			{
				return false;
			}
			cp949ToUtf16(petSource.data() + equipBase + 0x010u, 204u, equipment.alchemy);
			cp949ToUtf16(petSource.data() + equipBase + 0x0E6u, 29u, equipment.name);
			cp949ToUtf16(petSource.data() + equipBase + 0x103u, 17u, equipment.name2);
			cp949ToUtf16(petSource.data() + equipBase + 0x114u, 85u, equipment.memo);
			cp949ToUtf16(petSource.data() + equipBase + 0x169u, 16u, equipment.durability);
		}
	}
	return true;
}

bool readPetBlock(
	HMODULE module,
	const client_bindings::ResolvedAddresses& addresses,
	client05_readonly::PetBlockSnapshot& block,
	const client05_readonly::PetBlockSnapshot* previous,
	const wchar_t*& failedField) noexcept
{
	std::array<unsigned char, kPetArrayBytes> petA{};
	std::array<unsigned char, kPetArrayBytes> petB{};
	std::array<unsigned char, kPetSkillArrayBytes> skillA{};
	std::array<unsigned char, kPetSkillArrayBytes> skillB{};
	PetStateCoreSource stateA{};
	PetStateCoreSource stateB{};
	std::int32_t rideA = -1;
	std::int32_t rideB = -1;

	for (unsigned int attempt = 0u; attempt < kPetReadAttempts; ++attempt)
	{
		if (!readPetSources(module, addresses, petA, skillA, stateA, rideA, failedField))
			return false;
		MemoryBarrier();
		if (!readPetSources(module, addresses, petB, skillB, stateB, rideB, failedField))
			return false;
		if (petA == petB && skillA == skillB &&
			std::memcmp(&stateA, &stateB, sizeof(stateA)) == 0 &&
			rideA == rideB)
		{
			if (!populatePetBlock(petA, skillA, stateA, rideA, block))
			{
				failedField = L"pet block extraction";
				return false;
			}
			failedField = nullptr;
			return true;
		}
	}

	if (previous != nullptr)
	{
		block = *previous;
		failedField = nullptr;
		return true;
	}
	failedField = L"pet block coherence";
	return false;
}

bool readBattleScalars(
	HMODULE module,
	const client_bindings::ResolvedAddresses& addresses,
	battle_snapshot_parser::BattleScalars& scalars,
	const wchar_t*& failedField) noexcept
{
	const std::array<FieldRead, 7u> fields{
		FieldRead{ L"BattleMyNo", addresses.battleMyNo, &scalars.myPos, sizeof(scalars.myPos) },
		FieldRead{ L"BattleMyMp", addresses.battleMyMp, &scalars.myMp, sizeof(scalars.myMp) },
		FieldRead{ L"BattleBpFlag", addresses.battleBpFlag, &scalars.bpFlags, sizeof(scalars.bpFlags) },
		FieldRead{ L"BattleAnimFlag", addresses.battleAnimFlag, &scalars.actedMask, sizeof(scalars.actedMask) },
		FieldRead{ L"BattleCliTurnNo", addresses.battleCliTurnNo, &scalars.clientTurn, sizeof(scalars.clientTurn) },
		FieldRead{ L"BattleSvTurnNo", addresses.battleSvTurnNo, &scalars.serverTurn, sizeof(scalars.serverTurn) },
		FieldRead{ L"bNewServer", addresses.bNewServer, &scalars.newServer, sizeof(scalars.newServer) },
	};
	for (const auto& field : fields)
	{
		const auto* source = reinterpret_cast<const void*>(field.address);
		if (!isReadableClientRange(module, source, field.size) ||
			!guardedCopy(source, field.destination, field.size))
		{
			failedField = field.name;
			return false;
		}
	}
	return true;
}

bool readBattleStatus(
	HMODULE module,
	std::uintptr_t address,
	std::array<unsigned char, battle_snapshot_parser::kBattleStatusBytes>& status,
	const wchar_t*& failedField) noexcept
{
	const auto* source = reinterpret_cast<const void*>(address);
	if (!isReadableClientRange(module, source, status.size()) ||
		!guardedCopy(source, status.data(), status.size()))
	{
		failedField = L"BattleStatus[4096]";
		return false;
	}
	return true;
}

bool readBattleBlock(
	HMODULE module,
	const client_bindings::ResolvedAddresses& addresses,
	client05_readonly::BattleSnapshot& block,
	const client05_readonly::BattleSnapshot* previous,
	const wchar_t*& failedField) noexcept
{
	std::array<unsigned char, battle_snapshot_parser::kBattleStatusBytes> statusA{};
	std::array<unsigned char, battle_snapshot_parser::kBattleStatusBytes> statusB{};
	battle_snapshot_parser::BattleScalars scalarsA{};
	battle_snapshot_parser::BattleScalars scalarsB{};

	for (unsigned int attempt = 0u; attempt < kBattleReadAttempts; ++attempt)
	{
		if (!readBattleScalars(module, addresses, scalarsA, failedField) ||
			!readBattleStatus(module, addresses.battleStatus, statusA, failedField))
		{
			return false;
		}
		MemoryBarrier();
		if (!readBattleStatus(module, addresses.battleStatus, statusB, failedField) ||
			!readBattleScalars(module, addresses, scalarsB, failedField))
		{
			return false;
		}
		if (statusA != statusB ||
			std::memcmp(&scalarsA, &scalarsB, sizeof(scalarsA)) != 0)
		{
			continue;
		}

		client05_readonly::BattleSnapshot parsed{};
		if (!battle_snapshot_parser::parseBattleStatus(statusA, scalarsA, parsed))
			break;
		if (parsed.count == 0u && previous != nullptr && previous->count > 0u)
		{
			block = *previous;
			block.myPos = parsed.myPos; block.myMp = parsed.myMp; block.bpFlags = parsed.bpFlags;
			block.actedMask = parsed.actedMask; block.clientTurn = parsed.clientTurn;
			block.serverTurn = parsed.serverTurn; block.round = parsed.round;
			block.field = parsed.field; block.active = parsed.active;
			failedField = nullptr;
			return true;
		}
		block = parsed;
		failedField = nullptr;
		return true;
	}

	if (previous != nullptr)
	{
		block = *previous;
		failedField = nullptr;
		return true;
	}
	failedField = L"battle block coherence/parser";
	return false;
}

bool readItemSources(
	HMODULE module,
	const client_bindings::ResolvedAddresses& addresses,
	std::array<unsigned char, item_snapshot_parser::kItemSourceBytes>& items,
	std::int32_t& itemWndMaxBag,
	const wchar_t*& failedField) noexcept
{
	const std::array<FieldRead, 2u> fields{
		FieldRead{ L"PC.item[54]", addresses.itemBase, items.data(), items.size() },
		FieldRead{ L"itemWndMaxBag", addresses.itemWndMaxBag, &itemWndMaxBag, sizeof(itemWndMaxBag) },
	};
	for (const auto& field : fields)
	{
		const auto* source = reinterpret_cast<const void*>(field.address);
		if (!isReadableClientRange(module, source, field.size) ||
			!guardedCopy(source, field.destination, field.size))
		{
			failedField = field.name;
			return false;
		}
	}
	return true;
}

bool readItemBlock(
	HMODULE module,
	const client_bindings::ResolvedAddresses& addresses,
	client05_readonly::ItemBlockSnapshot& block,
	const client05_readonly::ItemBlockSnapshot* previous,
	const wchar_t*& failedField) noexcept
{
	std::array<unsigned char, item_snapshot_parser::kItemSourceBytes> itemA{};
	std::array<unsigned char, item_snapshot_parser::kItemSourceBytes> itemB{};
	std::int32_t pageA = -1;
	std::int32_t pageB = -1;
	for (unsigned int attempt = 0u; attempt < kItemReadAttempts; ++attempt)
	{
		if (!readItemSources(module, addresses, itemA, pageA, failedField))
			return false;
		MemoryBarrier();
		if (!readItemSources(module, addresses, itemB, pageB, failedField))
			return false;
		if (itemA != itemB || pageA != pageB)
			continue;
		if (!item_snapshot_parser::parseItemBlock(itemA, pageA, block))
			break;
		failedField = nullptr;
		return true;
	}
	if (previous != nullptr)
	{
		block = *previous;
		failedField = nullptr;
		return true;
	}
	failedField = L"item block coherence/parser";
	return false;
}

bool readCharacterBlock(HMODULE module, const client_bindings::ResolvedAddresses& addresses,
	client05_readonly::CharacterSnapshot& block, const client05_readonly::CharacterSnapshot* previous,
	const wchar_t*& failedField) noexcept
{
	using namespace character_snapshot_parser;
	std::array<unsigned char, kCoreBytes> coreA{}, coreB{};
	std::array<unsigned char, kFamilyBytes> familyA{}, familyB{};
	std::array<unsigned char, kProfessionBytes> professionA{}, professionB{};
	std::int32_t pointA = 0, pointB = 0, hourA = 0, hourB = 0; std::int16_t serverA = -1, serverB = -1;
	for (unsigned int attempt = 0u; attempt < kCharacterReadAttempts; ++attempt)
	{
		auto read = [&](auto& core, auto& family, auto& profession, std::int32_t& point, std::int32_t& hour, std::int16_t& server) {
			const std::array<FieldRead, 6u> fields{ FieldRead{ L"PC.core", addresses.pc, core.data(), core.size() },
				FieldRead{ L"PC.family", addresses.pc + 0x50F0u, family.data(), family.size() }, FieldRead{ L"PC.profession", addresses.pc + 0xA17Cu, profession.data(), profession.size() },
				FieldRead{ L"StatusUpPoint", addresses.statusUpPoint, &point, sizeof(point) }, FieldRead{ L"SaTime.hour", addresses.saTimeHour, &hour, sizeof(hour) }, FieldRead{ L"selectServerIndex", addresses.selectServerIndex, &server, sizeof(server) } };
			for (const auto& field : fields) if (!isReadableClientRange(module, reinterpret_cast<const void*>(field.address), field.size) || !guardedCopy(reinterpret_cast<const void*>(field.address), field.destination, field.size)) { failedField = field.name; return false; } return true; };
		if (!read(coreA, familyA, professionA, pointA, hourA, serverA)) return false;
		MemoryBarrier();
		if (!read(coreB, familyB, professionB, pointB, hourB, serverB)) return false;
		if (coreA != coreB || familyA != familyB || professionA != professionB || pointA != pointB || hourA != hourB || serverA != serverB) continue;
		if (parseCharacter(coreA, familyA, professionA, pointA, hourA, serverA, block)) { failedField = nullptr; return true; }
	}
	if (previous != nullptr) { block = *previous; failedField = nullptr; return true; }
	failedField = L"character block coherence/parser"; return false;
}

bool readDialogBlock(HMODULE module, const client_bindings::ResolvedAddresses& addresses,
	client05_readonly::DialogSnapshot& block, const client05_readonly::DialogSnapshot* previous,
	const wchar_t*& failedField) noexcept
{
	using namespace dialog_snapshot_parser;
	DialogScalars first{}, second{};
	MessageSource messageFirst{}, messageSecond{};
	auto read = [&](DialogScalars& scalars, MessageSource& message) {
		const std::array<FieldRead, 6u> fields{
			FieldRead{ L"windowTypeWN", addresses.windowTypeWN, &scalars.windowType, sizeof(scalars.windowType) },
			FieldRead{ L"buttonTypeWN", addresses.buttonTypeWN, &scalars.buttonType, sizeof(scalars.buttonType) },
			FieldRead{ L"indexWN", addresses.indexWN, &scalars.index, sizeof(scalars.index) },
			FieldRead{ L"idWN", addresses.idWN, &scalars.id, sizeof(scalars.id) },
			FieldRead{ L"msgWN[25][256]", addresses.msgWN, message.data(), message.size() },
			FieldRead{ L"selStartLine", addresses.selStartLine, &scalars.selStartLine, sizeof(scalars.selStartLine) },
		};
		for (const auto& field : fields)
			if (!isReadableClientRange(module, reinterpret_cast<const void*>(field.address), field.size) ||
				!guardedCopy(reinterpret_cast<const void*>(field.address), field.destination, field.size))
			{
				failedField = field.name;
				return false;
			}
		return true;
	};
	for (unsigned int attempt = 0u; attempt < kDialogReadAttempts; ++attempt)
	{
		if (!read(first, messageFirst)) return false;
		MemoryBarrier();
		if (!read(second, messageSecond)) return false;
		if (!sourcesEqual(first, messageFirst, second, messageSecond)) continue;
		parseDialog(first, messageFirst, block);
		failedField = nullptr;
		return true;
	}
	if (previous != nullptr) { block = *previous; failedField = nullptr; return true; }
	failedField = L"dialog block coherence";
	return false;
}

bool readSkillTeamBlocks(HMODULE module, const client_bindings::ResolvedAddresses& addresses,
	client05_readonly::SkillMagicCardSnapshot& skillBlock,
	client05_readonly::TeamUnitSnapshot& teamBlock,
	const Snapshot* previous, const wchar_t*& failedField) noexcept
{
	using namespace skill_team_snapshot_parser;
	struct Sources { SkillSource skill{}; MagicSource magic{}; CardSource card{}; PartySource party{}; UnitSource unit{}; };
	auto first = std::make_unique<Sources>();
	auto second = std::make_unique<Sources>();
	if (!first || !second) { failedField = L"skill/team source allocation"; return false; }
	auto read = [&](Sources& source) {
		const std::array<FieldRead, 5u> fields{
			FieldRead{ L"profession_skill[26]", addresses.professionSkill, source.skill.data(), source.skill.size() },
			FieldRead{ L"magic[9]", addresses.magic, source.magic.data(), source.magic.size() },
			FieldRead{ L"addressBook[80]", addresses.addressBook, source.card.data(), source.card.size() },
			FieldRead{ L"party[5]", addresses.party, source.party.data(), source.party.size() },
			FieldRead{ L"charObj[1500]", addresses.charObj, source.unit.data(), source.unit.size() },
		};
		for (const auto& field : fields)
			if (!isReadableClientRange(module, reinterpret_cast<const void*>(field.address), field.size) ||
				!guardedCopy(reinterpret_cast<const void*>(field.address), field.destination, field.size))
			{ failedField = field.name; return false; }
		return true;
	};
	for (unsigned int attempt = 0u; attempt < kSkillTeamReadAttempts; ++attempt)
	{
		if (!read(*first)) return false;
		MemoryBarrier();
		if (!read(*second)) return false;
		if (first->skill != second->skill || first->magic != second->magic || first->card != second->card || first->party != second->party || first->unit != second->unit) continue;
		if (!parseBlocks(first->skill, first->magic, first->card, first->party, first->unit, skillBlock, teamBlock))
		{ failedField = L"skill/team block extraction"; return false; }
		failedField = nullptr;
		return true;
	}
	if (previous != nullptr) { skillBlock = previous->skillMagicCard; teamBlock = previous->teamUnit; failedField = nullptr; return true; }
	failedField = L"skill/team block coherence";
	return false;
}

bool readMailHistoryBlock(HMODULE module, const client_bindings::ResolvedAddresses& addresses,
	client05_readonly::MailHistoryBlockSnapshot& block,
	const client05_readonly::MailHistoryBlockSnapshot* previous, const wchar_t*& failedField) noexcept
{
	using namespace mail_history_snapshot_parser;
	auto rawA = std::make_unique<Source>();
	auto rawB = std::make_unique<Source>();
	if (!rawA || !rawB)
	{
		failedField = L"MailHistory source allocation";
		return false;
	}
	const auto* source = reinterpret_cast<const void*>(addresses.mailHistory);
	if (!isReadableClientRange(module, source, kMailSourceBytes))
	{
		failedField = L"MailHistory[80][20]";
		return false;
	}
	for (unsigned int attempt = 0u; attempt < kMailHistoryReadAttempts; ++attempt)
	{
		// No client-side mail epoch exists. Equal A/B copies are only a best-effort
		// torn-read reduction, not an atomic source snapshot; retain previous-good
		// data if no equal pair is observed rather than publishing an unstable read.
		if (!guardedCopy(source, rawA->data(), rawA->size()))
		{
			failedField = L"MailHistory[80][20]";
			return false;
		}
		MemoryBarrier();
		if (!guardedCopy(source, rawB->data(), rawB->size()))
		{
			failedField = L"MailHistory[80][20]";
			return false;
		}
		if (*rawA != *rawB)
			continue;
		client05_readonly::MailHistoryBlockSnapshot candidate{};
		if (!parseBlock(*rawA, candidate))
		{
			failedField = L"MailHistory parser";
			return false;
		}
		block = candidate;
		failedField = nullptr;
		return true;
	}
	if (previous != nullptr)
	{
		block = *previous;
		failedField = nullptr;
		return true;
	}
	failedField = L"MailHistory block coherence";
	return false;
}

bool readShopChatMapBlock(HMODULE module, const client_bindings::ResolvedAddresses& addresses,
	client05_readonly::ShopChatMapSnapshot& block,
	const client05_readonly::ShopChatMapSnapshot* previous, const wchar_t*& failedField) noexcept
{
	using namespace shop_chat_map_snapshot_parser;
	struct Sources { ChatSource chat{}; ItemShopSource items{}; SkillShopSource skills{}; PoolShopSource pool{}; FamilyListSource families{}; AuctionSource auctions{}; PlaneSource ground{}, object{}, event{}, hit{}; MapMeta meta{}; std::int32_t next = 0, windowType = 0; std::int16_t shop = 0; };
	Sources first{}, second{};
	auto read = [&](Sources& source) {
		const std::array<FieldRead, 19u> fields{
			FieldRead{ L"shopWindowMode", addresses.shopWindowMode, &source.shop, sizeof(source.shop) }, FieldRead{ L"NowChatLine", addresses.nowChatLine, &source.next, sizeof(source.next) },
			FieldRead{ L"windowTypeWN", addresses.windowTypeWN, &source.windowType, sizeof(source.windowType) },
			FieldRead{ L"sealItem[32]", addresses.sealItem, source.items.data(), source.items.size() }, FieldRead{ L"sealSkill[80]", addresses.sealSkill, source.skills.data(), source.skills.size() }, FieldRead{ L"poolItem[104]", addresses.poolItem, source.pool.data(), source.pool.size() },
			FieldRead{ L"ChatBuffer[30]", addresses.chatBuffer, source.chat.data(), source.chat.size() }, FieldRead{ L"mapFloorSize", addresses.mapFloorSize, &source.meta.floorWidth, 8u },
			FieldRead{ L"mapArea", addresses.mapArea, &source.meta.x1, 24u }, FieldRead{ L"map.tile", addresses.mapTile, source.ground.data(), source.ground.size() }, FieldRead{ L"map.parts", addresses.mapParts, source.object.data(), source.object.size() },
			FieldRead{ L"map.event", addresses.mapEvent, source.event.data(), source.event.size() }, FieldRead{ L"map.hit", addresses.mapHit, source.hit.data(), source.hit.size() },
			FieldRead{ L"nowFloor", addresses.nowFloor, &source.meta.floor, sizeof(source.meta.floor) },
			FieldRead{ L"nowGx", addresses.nowGx, &source.meta.playerX, sizeof(source.meta.playerX) }, FieldRead{ L"nowGy", addresses.nowGy, &source.meta.playerY, sizeof(source.meta.playerY) },
			FieldRead{ L"nowFloorName", addresses.nowFloorName, source.meta.name.data(), 25u },
			FieldRead{ L"familyList[10]", addresses.familyList, source.families.data(), source.families.size() }, FieldRead{ L"aldArea[10]", addresses.auctionList, source.auctions.data(), source.auctions.size() },
		};
		for (const auto& field : fields) if (!isReadableClientRange(module, reinterpret_cast<const void*>(field.address), field.size) || !guardedCopy(reinterpret_cast<const void*>(field.address), field.destination, field.size)) { failedField = field.name; return false; }
		return true;
	};
	// shop/chat/map is read-only DISPLAY data. Its large map-tile planes contain animated
	// cells that change between reads, so a whole-struct A/B coherence check almost never
	// matches and previously left the block blank. Read a few times to PREFER a clean pair,
	// then publish the latest read best-effort even if not perfectly coherent: parse() below
	// validates every bound, and the family/auction record arrays are still guarded from torn
	// reads by the multi-tick stability gate. A genuinely unreadable address (read() == false)
	// is still surfaced as a real failure.
	for (unsigned int shopAttempt = 0u; shopAttempt < 4u; ++shopAttempt)
	{
		if (!read(first)) return false; MemoryBarrier(); if (!read(second)) return false;
		if (std::memcmp(&first, &second, sizeof(Sources)) == 0) break;
	}
	if (!parse(first.chat, first.next, first.shop, first.windowType, first.items, first.skills, first.pool, first.meta, first.ground, first.object, first.event, first.hit, first.families, first.auctions, block)) { if (previous != nullptr) { block = *previous; } else { block = {}; } failedField = nullptr; return true; }
	// The module arrays can outlive their UI.  Publish family/auction only after the same
	// bounded candidate is observed on consecutive polling ticks; otherwise mark warming.
	static client05_readonly::ShopWindowsSnapshot lastCandidate{};
	static bool haveLastCandidate = false;
	const auto candidate = block.windows;
	auto gate = [&](std::uint32_t& state, std::uint32_t& count, auto& records, std::uint32_t previousState, std::uint32_t previousCount, const auto& previousRecords) {
		if (state == 0u) return;
		const bool stable = haveLastCandidate && previousState == 2u && count == previousCount && std::memcmp(records.data(), previousRecords.data(), sizeof(records)) == 0;
		if (!stable) { state = 1u; count = 0u; records = {}; }
	};
	gate(block.windows.familyState, block.windows.familyCount, block.windows.families, lastCandidate.familyState, lastCandidate.familyCount, lastCandidate.families);
	gate(block.windows.auctionState, block.windows.auctionCount, block.windows.auctions, lastCandidate.auctionState, lastCandidate.auctionCount, lastCandidate.auctions);
	lastCandidate = candidate; haveLastCandidate = true;
	failedField = nullptr; return true;
}

bool readSnapshot(
	HMODULE module,
	const client_bindings::ResolvedAddresses& addresses,
	Snapshot& snapshot,
	const Snapshot* previous,
	const wchar_t*& failedField) noexcept
{
	const std::array<FieldRead, 11u> fields{
		FieldRead{ L"sockfd", addresses.sockfd, &snapshot.sockfd, sizeof(snapshot.sockfd) },
		FieldRead{ L"ProcNo", addresses.procNo, &snapshot.procNo, sizeof(snapshot.procNo) },
		FieldRead{ L"SubProcNo", addresses.subProcNo, &snapshot.subProcNo, sizeof(snapshot.subProcNo) },
		FieldRead{ L"BattlingFlag", addresses.battlingFlag, &snapshot.battlingFlag, sizeof(snapshot.battlingFlag) },
		FieldRead{ L"encountNowFlag", addresses.encountNowFlag, &snapshot.encountNowFlag, sizeof(snapshot.encountNowFlag) },
		FieldRead{ L"bNewServer", addresses.bNewServer, &snapshot.newServer, sizeof(snapshot.newServer) },
		FieldRead{ L"selectServerIndex", addresses.selectServerIndex, &snapshot.selectServerIndex, sizeof(snapshot.selectServerIndex) },
		FieldRead{ L"nowFloor", addresses.nowFloor, &snapshot.nowFloor, sizeof(snapshot.nowFloor) },
		FieldRead{ L"nowFloorName", addresses.nowFloorName, snapshot.nowFloorName.data(), kFloorNameBytes },
		FieldRead{ L"nowGx", addresses.nowGx, &snapshot.nowGx, sizeof(snapshot.nowGx) },
		FieldRead{ L"nowGy", addresses.nowGy, &snapshot.nowGy, sizeof(snapshot.nowGy) },
	};

	for (const auto& field : fields)
	{
		const auto* source = reinterpret_cast<const void*>(field.address);
		if (!isReadableClientRange(module, source, field.size) ||
			!guardedCopy(source, field.destination, field.size))
		{
			failedField = field.name;
			return false;
		}
	}

	snapshot.nowFloorName[kFloorNameBytes] = '\0';
	if (!readDialogBlock(module, addresses, snapshot.dialog,
		previous == nullptr ? nullptr : &previous->dialog, failedField))
		return false;
	if (!readSkillTeamBlocks(module, addresses, snapshot.skillMagicCard, snapshot.teamUnit,
		previous, failedField))
		return false;
	if (!readMailHistoryBlock(module, addresses, snapshot.mailHistory,
		previous == nullptr ? nullptr : &previous->mailHistory, failedField))
		return false;
	if (!readShopChatMapBlock(module, addresses, snapshot.shopChatMap,
		previous == nullptr ? nullptr : &previous->shopChatMap, failedField))
		return false;
	if (!readCharacterBlock(module, addresses, snapshot.character,
		previous == nullptr ? nullptr : &previous->character, failedField))
		return false;
	if (!readPetBlock(module, addresses, snapshot.petBlock,
		previous == nullptr ? nullptr : &previous->petBlock, failedField))
	{
		return false;
	}
	if (!readItemBlock(module, addresses, snapshot.itemBlock,
		previous == nullptr ? nullptr : &previous->itemBlock, failedField))
	{
		return false;
	}
	if (snapshot.procNo == kProcBattle)
	{
		if (!readBattleBlock(module, addresses, snapshot.battle,
			previous == nullptr ? nullptr : &previous->battle, failedField))
		{
			return false;
		}
	}
	else
	{
		snapshot.battle = {};
	}
	failedField = nullptr;
	return true;
}

bool isSnapshotSane(const Snapshot& snapshot, const wchar_t*& failedField) noexcept
{
	if (snapshot.battlingFlag < 0 || snapshot.battlingFlag > 0xFFFF)
	{
		failedField = L"BattlingFlag";
		return false;
	}
	// bNewServer legitimately holds large non-bool values in-world (e.g. 0x0F000001); not a corruption indicator, so it is not gated in isSnapshotSane.
	if (snapshot.procNo > 0xFFFFu || snapshot.subProcNo > 0xFFFFu)
	{
		failedField = snapshot.procNo > 0xFFFFu ? L"ProcNo" : L"SubProcNo";
		return false;
	}
	constexpr int kCoordinateLimit = 1000000;
	if (snapshot.nowFloor < -kCoordinateLimit || snapshot.nowFloor > kCoordinateLimit ||
		snapshot.nowGx < -kCoordinateLimit || snapshot.nowGx > kCoordinateLimit ||
		snapshot.nowGy < -kCoordinateLimit || snapshot.nowGy > kCoordinateLimit)
	{
		failedField = L"nowFloor/nowGx/nowGy";
		return false;
	}
	failedField = nullptr;
	return true;
}

std::wstring makeLogPath() noexcept
{
	try
	{
		std::array<wchar_t, 32768u> path{};
		const DWORD length = GetModuleFileNameW(nullptr, path.data(), static_cast<DWORD>(path.size()));
		if (length == 0u || length >= path.size())
			return {};
		std::wstring result(path.data(), length);
		const auto separator = result.find_last_of(L"\\/");
		if (separator == std::wstring::npos)
			return {};
		result.resize(separator + 1u);
		result += L"sash-client05-readonly.log";
		return result;
	}
	catch (...)
	{
		return {};
	}
}

bool appendUtf8Line(const std::wstring& path, const std::wstring& text) noexcept
{
	if (path.empty())
		return false;
	try
	{
		std::wstring line = text;
		line += L"\r\n";
		const int required = WideCharToMultiByte(CP_UTF8, 0, line.data(), static_cast<int>(line.size()),
			nullptr, 0, nullptr, nullptr);
		if (required <= 0)
			return false;
		std::string utf8(static_cast<std::size_t>(required), '\0');
		if (WideCharToMultiByte(CP_UTF8, 0, line.data(), static_cast<int>(line.size()),
			utf8.data(), required, nullptr, nullptr) != required)
		{
			return false;
		}
		HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
			nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
		if (file == INVALID_HANDLE_VALUE)
			return false;
		DWORD written = 0u;
		const BOOL ok = WriteFile(file, utf8.data(), static_cast<DWORD>(utf8.size()), &written, nullptr);
		CloseHandle(file);
		return ok != FALSE && written == utf8.size();
	}
	catch (...)
	{
		return false;
	}
}

std::wstring floorNameToWide(const Snapshot& snapshot)
{
	const auto nameEnd = std::find(
		snapshot.nowFloorName.begin(),
		snapshot.nowFloorName.begin() + kFloorNameBytes,
		'\0');
	const std::size_t length = static_cast<std::size_t>(nameEnd - snapshot.nowFloorName.begin());
	if (length == 0u)
		return {};
	const int required = MultiByteToWideChar(949u, 0, snapshot.nowFloorName.data(),
		static_cast<int>(length), nullptr, 0);
	if (required <= 0)
		return L"<invalid-cp949>";
	std::wstring result(static_cast<std::size_t>(required), L'\0');
	if (MultiByteToWideChar(949u, 0, snapshot.nowFloorName.data(), static_cast<int>(length),
		result.data(), required) != required)
	{
		return L"<invalid-cp949>";
	}
	return result;
}

std::wstring timestamp()
{
	SYSTEMTIME time{};
	GetLocalTime(&time);
	wchar_t buffer[32u]{};
	swprintf_s(buffer, L"%04u-%02u-%02u %02u:%02u:%02u.%03u",
		time.wYear, time.wMonth, time.wDay, time.wHour, time.wMinute,
		time.wSecond, time.wMilliseconds);
	return buffer;
}

void logSnapshot(const MonitorContext& context, const wchar_t* stage, const Snapshot& snapshot)
{
	std::wostringstream line;
	line << L"[" << timestamp() << L"] [snapshot:" << stage << L"] "
		<< L"sockfd=" << snapshot.sockfd
		<< L" ProcNo=" << snapshot.procNo
		<< L" SubProcNo=" << snapshot.subProcNo
		<< L" BattlingFlag=" << snapshot.battlingFlag
		<< L" encountNowFlag=" << snapshot.encountNowFlag
		<< L" bNewServer=" << snapshot.newServer
		<< L" selectServerIndex=" << snapshot.selectServerIndex
		<< L" nowFloor=" << snapshot.nowFloor
		<< L" nowFloorName=\"" << floorNameToWide(snapshot) << L"\""
		<< L" nowGx=" << snapshot.nowGx
		<< L" nowGy=" << snapshot.nowGy;
	appendUtf8Line(context.logPath, line.str());
}

void publishSpeedAck(
	MonitorContext& context,
	LONG sequence,
	client05_readonly::SpeedResult result,
	client05_readonly::RestoreReason restoreReason,
	DWORD surfaceDateAfter) noexcept
{
	if (context.channel == nullptr)
		return;
	InterlockedExchange(&context.channel->speedResult, static_cast<LONG>(result));
	InterlockedExchange(&context.channel->appliedSystemTime,
		static_cast<LONG>(context.appliedSystemTime));
	InterlockedExchange(&context.channel->originalSystemTime,
		static_cast<LONG>(context.originalSystemTime));
	InterlockedExchange(&context.channel->surfaceDateBefore,
		static_cast<LONG>(context.surfaceDateBefore));
	InterlockedExchange(&context.channel->surfaceDateAfter,
		static_cast<LONG>(surfaceDateAfter));
	InterlockedExchange(&context.channel->restoreReason, static_cast<LONG>(restoreReason));
	MemoryBarrier();
	InterlockedExchange(&context.channel->speedAckSequence, sequence);
}

void logSpeedResult(
	const MonitorContext& context,
	const wchar_t* stage,
	LONG sequence,
	client05_readonly::SpeedResult result,
	client05_readonly::RestoreReason restoreReason,
	DWORD surfaceDateAfter)
{
	std::wostringstream line;
	line << L"[" << timestamp() << L"] [speed:" << stage << L"] sequence=" << sequence
		<< L" mode=" << static_cast<LONG>(context.activeSpeedMode)
		<< L" result=" << static_cast<LONG>(result)
		<< L" originalSystemTime=" << context.originalSystemTime
		<< L" appliedSystemTime=" << context.appliedSystemTime
		<< L" surfaceDateBefore=" << context.surfaceDateBefore
		<< L" surfaceDateAfter=" << surfaceDateAfter
		<< L" delta=" << static_cast<DWORD>(surfaceDateAfter - context.surfaceDateBefore)
		<< L" restoreReason=" << static_cast<LONG>(restoreReason);
	appendUtf8Line(context.logPath, line.str());
}

void publishAutoLoginAck(
	MonitorContext& context,
	LONG sequence,
	client05_readonly::AutoLoginResult result,
	LONG verifiedControlCount) noexcept
{
	if (context.channel == nullptr)
		return;
	client05_readonly::clearLoginCommandPayload(*context.channel);
	InterlockedExchange(&context.channel->loginResult, static_cast<LONG>(result));
	InterlockedExchange(&context.channel->loginVerifiedControlCount, verifiedControlCount);
	InterlockedExchange(&context.channel->loginApplyCompleted,
		result == client05_readonly::AutoLoginResult::success ? TRUE : FALSE);
	MemoryBarrier();
	InterlockedExchange(&context.channel->loginAckSequence, sequence);
}

void logAutoLoginResult(
	const MonitorContext& context,
	const wchar_t* stage,
	LONG sequence,
	client05_readonly::AutoLoginResult result,
	LONG accountLength,
	LONG passwordLength,
	LONG server,
	LONG subserver,
	LONG character,
	LONG verifiedControlCount)
{
	std::wostringstream line;
	line << L"[" << timestamp() << L"] [auto_login:" << stage << L"] sequence=" << sequence
		<< L" result=" << static_cast<LONG>(result)
		<< L" accountLength=" << accountLength
		<< L" passwordLength=" << passwordLength
		<< L" server=" << server
		<< L" subserver=" << subserver
		<< L" character=" << character
		<< L" verifiedControls=" << verifiedControlCount
		<< L" accountRedacted=true passwordRedacted=true";
	appendUtf8Line(context.logPath, line.str());
}

void rejectAutoLoginCommand(
	MonitorContext& context,
	LONG sequence,
	client05_readonly::AutoLoginResult result,
	LONG accountLength,
	LONG passwordLength,
	LONG server,
	LONG subserver,
	LONG character,
	LONG verifiedControlCount = 0L) noexcept
{
	publishAutoLoginAck(context, sequence, result, verifiedControlCount);
	logAutoLoginResult(context, L"rejected", sequence, result, accountLength, passwordLength,
		server, subserver, character, verifiedControlCount);
}

// [BlackWatch] dedicated 5ms sampler thread: SurfaceDate(0x593EE8) increments once per REAL drawn frame
// (client draw path 0x433C65). When it stalls, the field shows black/frozen. Log every no-draw GAP (>=70ms)
// and a 1s heartbeat with WALL-CLOCK time + full draw+net state, so a black flash at a noted clock time is
// matched to loop state. Fields: floor=nowFloor(map id; changes=map transition/disk load), rbl/wbl=net read/
// write buf len, snd=netproc_sending, sock=sockfd (server-wait shows here). Independent of the 50ms monitor loop.
static DWORD WINAPI blackWatchProc(LPVOID)
{
	const std::uintptr_t b = reinterpret_cast<std::uintptr_t>(GetModuleHandleW(nullptr));
	if (b == 0) { return 0; }
	volatile unsigned int* const bwFrame = reinterpret_cast<volatile unsigned int*>(b + 0x00193EE8u);
	volatile int* const bwNdc   = reinterpret_cast<volatile int*>(b + 0x00171524u);
	volatile int* const bwNdMax = reinterpret_cast<volatile int*>(b + 0x00171518u);
	volatile int* const bwSys   = reinterpret_cast<volatile int*>(b + 0x00171520u);
	volatile int* const bwProc  = reinterpret_cast<volatile int*>(b + 0x0017151Cu);
	volatile int* const bwGsf   = reinterpret_cast<volatile int*>(b + 0x002AE6F8u);
	volatile int* const bwPx    = reinterpret_cast<volatile int*>(b + 0x00B8DE0D8u);
	volatile int* const bwPy    = reinterpret_cast<volatile int*>(b + 0x00B8DE0DCu);
	volatile int* const bwFloor = reinterpret_cast<volatile int*>(b + 0x00B8DE0CCu);
	volatile int* const bwRbl   = reinterpret_cast<volatile int*>(b + 0x00B971B88u);
	volatile int* const bwWbl   = reinterpret_cast<volatile int*>(b + 0x00B971B8Cu);
	volatile int* const bwSnd   = reinterpret_cast<volatile int*>(b + 0x00B97615Cu);
	volatile int* const bwSock  = reinterpret_cast<volatile int*>(b + 0x00B971B90u);
	unsigned int lastFrame = *bwFrame;
	DWORD lastChange = GetTickCount();
	DWORD lastBeat = lastChange;
	unsigned int beatBaseFrame = lastFrame;
	int gapOpen = 0;
	for (;;)
	{
		Sleep(5);
		const DWORD nowT = GetTickCount();
		const unsigned int f = *bwFrame;
		SYSTEMTIME st; GetLocalTime(&st);
		char wc[16]; wsprintfA(wc, "%02d:%02d:%02d.%03d", st.wHour, st.wMinute, st.wSecond, st.wMilliseconds);
		if (f != lastFrame)
		{
			if (gapOpen)
			{
				const DWORD gap = nowT - lastChange;
				HANDLE h = CreateFileW(L"C:\\zmffk\\blackwatch.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
				if (h != INVALID_HANDLE_VALUE) { char bb[384]; int n = wsprintfA(bb, "%s GAP-END dur=%ums frame=%u ndc=%d ndmax=%d sys=%d proc=%d gsf=%d floor=%d rbl=%d wbl=%d snd=%d sock=%d pos=(%d,%d)\r\n", wc, gap, f, *bwNdc, *bwNdMax, *bwSys, *bwProc, *bwGsf, *bwFloor, *bwRbl, *bwWbl, *bwSnd, *bwSock, *bwPx, *bwPy); DWORD w = 0; WriteFile(h, bb, (DWORD)n, &w, nullptr); CloseHandle(h); }
				gapOpen = 0;
			}
			lastFrame = f; lastChange = nowT;
		}
		else
		{
			const DWORD gap = nowT - lastChange;
			if (gap >= 70u && !gapOpen)
			{
				gapOpen = 1;
				HANDLE h = CreateFileW(L"C:\\zmffk\\blackwatch.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
				if (h != INVALID_HANDLE_VALUE) { char bb[384]; int n = wsprintfA(bb, "%s GAP-START gap=%ums frame=%u ndc=%d ndmax=%d sys=%d proc=%d gsf=%d floor=%d rbl=%d wbl=%d snd=%d sock=%d pos=(%d,%d)\r\n", wc, gap, f, *bwNdc, *bwNdMax, *bwSys, *bwProc, *bwGsf, *bwFloor, *bwRbl, *bwWbl, *bwSnd, *bwSock, *bwPx, *bwPy); DWORD w = 0; WriteFile(h, bb, (DWORD)n, &w, nullptr); CloseHandle(h); }
			}
		}
		if (nowT - lastBeat >= 1000u)
		{
			const unsigned int fps = (f >= beatBaseFrame) ? (f - beatBaseFrame) : 0u;
			beatBaseFrame = f; lastBeat = nowT;
			HANDLE h = CreateFileW(L"C:\\zmffk\\blackwatch.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
			if (h != INVALID_HANDLE_VALUE) { char bb[384]; int n = wsprintfA(bb, "%s HB fps=%u frame=%u ndc=%d ndmax=%d sys=%d proc=%d gsf=%d floor=%d rbl=%d wbl=%d snd=%d sock=%d pos=(%d,%d)\r\n", wc, fps, f, *bwNdc, *bwNdMax, *bwSys, *bwProc, *bwGsf, *bwFloor, *bwRbl, *bwWbl, *bwSnd, *bwSock, *bwPx, *bwPy); DWORD w = 0; WriteFile(h, bb, (DWORD)n, &w, nullptr); CloseHandle(h); }
		}
	}
}

// [FastEncWndProc] sa_8001-IDENTICAL fast-encounter (快速遇敵). The launcher's autoWalk FAST branch
// is worker->move(QPoint(0,0),"gcgc") = a WALK packet (lssproto_W2_send) carrying the in-place "gcgc"
// step string. Client05-native equivalent: call lssproto_W2_send(sockfd,gx,gy,"gcgc") on the MAIN
// thread. W2 is the ORDINARY walk packet the client sends constantly, so the server accepts it (no
// disconnect, unlike the EN_send experiment) and the in-place steps accrue encounters. Client05 has
// no legacy WndProc, so the monitor installs a MINIMAL subclass that ONLY intercepts kFeSendMsg
// (SendMessage-marshaled to the client MAIN thread) and chains everything else to the original.
// ASLR off => fixed client VAs: lssproto_W2_send@0x4B72E0 void __cdecl(int,int,int,char*);
// sockfd@0xBD71B90; BattlingFlag@0x64F83C; nowGx@0xBCDE0D8 nowGy@0xBCDE0DC.
static const UINT kFeSendMsg = WM_APP + 0x1ECu;
static const UINT kEscapeMsg = WM_APP + 0x1EDu;
	static const UINT kBattleActMsg = WM_APP + 0x1EEu;
	static const UINT kExpResultMsg = WM_APP + 0x1F0u;
	static volatile LONG g_baCharType = -1;
	static volatile LONG g_baCharTarget = 0;
	static volatile LONG g_baPetType = -1;
	static volatile LONG g_baPetTarget = 0;
	static DWORD g_baCharSentTick = 0;
	static DWORD g_baPetSentTick = 0;
	static volatile LONG g_baCharEnemy = 0;
	static volatile LONG g_baCharLevel = 0;
	static volatile LONG g_baAutoEscape = 0;
	static volatile LONG g_baFallEscape = 0;
	static int feBattleAlive(int pos) { if (pos < 0 || pos >= 20) return 0; const unsigned int ent = *(volatile unsigned int*)(0x0D6AEAA0u + (unsigned int)pos * 4u); if (ent == 0u) return 0; if (*(volatile unsigned int*)(ent + 8u) == 0u) return 0; if (*(volatile int*)(ent + 36u) != 0) return 0; if (*(volatile int*)(ent + 120u) <= 0) return 0; return 1; }
	static unsigned int feBObj(int pos) { if (pos < 0 || pos >= 20) return 0u; return *(volatile unsigned int*)(0x0D6AEAA0u + (unsigned int)pos * 4u); }
	static int feBCRideFlag(int myPos) {
		// [BC-rideFlag] launcher fallDownEscapeFun reads bt.objects[myPos].rideFlag from the BC packet (NOT client memory).
		// BC status buf @0x005A2DF8 (char[]): "BC|field|pos|name|free|model|lv|hp|max|status|rideFlag|rideName|rideLv|rideHp|rideMax|pos|...".
		// tokens: 0=BC,1=field; unit i pos@(i*13+2), rideFlag@(i*13+10)=pos+8. F0: tcpserver BC parse i*13+10. return 1=ride,0=fell,-1=unknown.
		const volatile char* bc = (const volatile char*)0x005A2DF8u;
		if (bc[0] != 'B' || bc[1] != 'C' || bc[2] != '|') return -1;
		int idx = 3, tokNum = 1, rideTok = -1;
		while (bc[idx] != '\0' && idx < 4096) {
			long v = 0; int any = 0, hexok = 1;
			while (bc[idx] != '\0' && bc[idx] != '|' && idx < 4096) {
				const char c = bc[idx++]; int dgt;
				if (c >= '0' && c <= '9') dgt = c - '0';
				else if (c >= 'A' && c <= 'F') dgt = c - 'A' + 10;
				else if (c >= 'a' && c <= 'f') dgt = c - 'a' + 10;
				else { hexok = 0; dgt = 0; }
				v = v * 16 + dgt; any = 1;
			}
			if (rideTok == tokNum) return (hexok && any) ? (int)v : -1;
			if (tokNum >= 2 && ((tokNum - 2) % 13) == 0 && hexok && any && v == (long)myPos) rideTok = tokNum + 8;
			if (bc[idx] == '|') ++idx;
			++tokNum;
		}
		return -1;
	}
	// valid battle unit = launcher bt.enemies criteria (modelid>0 && maxHp>0 && level>0 && !DEAD), client-native.
	static int feBValid(int pos) { unsigned int e = feBObj(pos); if (e == 0u) return 0; if (*(volatile unsigned int*)(e + 8u) == 0u) return 0; if (*(volatile int*)(e + 0x24u) != 0) return 0; if (*(volatile int*)(e + 0x78u) <= 0) return 0; if (*(volatile int*)(e + 0x80u) <= 0) return 0; if (*(volatile int*)(e + 0x8Cu) <= 0) return 0; return 1; }
	// compareBattleObjects (tcpserver 10151): hp asc, maxHp asc, level asc, then order table. returns 1 if a<b.
	static int feCmpBattle(int pa, int pb) {
		unsigned int ea = feBObj(pa), eb = feBObj(pb);
		int ha = *(volatile int*)(ea + 0x78u), hb = *(volatile int*)(eb + 0x78u); if (ha != hb) return ha < hb ? 1 : 0;
		int ma = *(volatile int*)(ea + 0x80u), mb = *(volatile int*)(eb + 0x80u); if (ma != mb) return ma < mb ? 1 : 0;
		int la = *(volatile int*)(ea + 0x8Cu), lb = *(volatile int*)(eb + 0x8Cu); if (la != lb) return la < lb ? 1 : 0;
		static const int order[20] = { 19,17,15,16,18,14,12,10,11,13,8,6,5,7,9,3,1,0,2,4 };
		int ia = 0, ib = 0; for (int k = 0; k < 20; ++k) { if (order[k] == pa) ia = k; if (order[k] == pb) ib = k; } return ia < ib ? 1 : 0;
	}
	// isTouchable (tcpserver 10231): a back-row pos is unreachable while its front-row counterpart is alive.
	static int feIsTouchable(int pos) {
		static const int bk[10] = { 13,11,10,12,14,3,1,0,2,4 };
		static const int fr[10] = { 18,16,15,17,19,8,6,5,7,9 };
		for (int k = 0; k < 10; ++k) { if (bk[k] == pos) { return feBValid(fr[k]) ? 0 : 1; } } return 1;
	}
	// feAiValid = GetBattelTarget per-slot predicate (battleMenu.cpp 3192): func!=NULL, hp>0, not self/own-pet.
	static int feAiValid(int index, int myNo) {
		unsigned int e = feBObj(index); if (e == 0u) return 0;
		if (*(volatile unsigned int*)(e + 8u) == 0u) return 0;   // p_party[index]->func == NULL
		if (*(volatile int*)(e + 0x78u) <= 0) return 0;          // p_party[index]->hp <= 0
		if (index == myNo || index == myNo + 5) return 0;        // skip self / own pet
		return 1;
	}
	// Client-native attack order (battleMenu.cpp Ordinal): enemy FRONT row top->bottom, then BACK row top->bottom.
	//   front(myNo<10) = 19,17,15,16,18 ; back = 14,12,10,11,13. This equals the F5 battle-situation display order
	//   the owner annotated (front 1..5, back R6..R10). Front entirely before back.
	static const int feOrdinal[20] = { 19,17,15,16,18, 14,12,10,11,13, 9,7,5,6,8, 4,2,0,1,3 };
	// getBattleSelectableEnemyTarget: first live enemy in the native display order (front-first, top->bottom).
	static int feSelectableEnemy(int myNo) {
		int i, end; if (myNo < 10) { i = 0; end = 10; } else { i = 10; end = 20; }
		for (; i < end; ++i) { int index = feOrdinal[i]; if (feAiValid(index, myNo)) return index; }
		return (myNo < 10) ? 19 : 5;
	}
	// EB (owner spec): enemy BACK row first (top->bottom), then FRONT row; same native predicate.
	static int feSelectableBackFirst(int myNo) {
		int bi, bend, fi, fend;
		if (myNo < 10) { bi = 5; bend = 10; fi = 0; fend = 5; }     // enemy back = Ordinal[5..9](10-14), front = Ordinal[0..4](15-19)
		else           { bi = 15; bend = 20; fi = 10; fend = 15; }  // enemy back = Ordinal[15..19](0-4), front = Ordinal[10..14](5-9)
		for (int i = bi; i < bend; ++i) { int index = feOrdinal[i]; if (feAiValid(index, myNo)) return index; }
		for (int i = fi; i < fend; ++i) { int index = feOrdinal[i]; if (feAiValid(index, myNo)) return index; }
		return (myNo < 10) ? 19 : 5;
	}
	// getBattleSelectableAllieTarget (tcpserver 10380): first valid ally after front-first sort.
	static int feSelectableAllie(int myNo) {
		int aMin, aMax; if (myNo < 10) { aMin = 0; aMax = 9; } else { aMin = 10; aMax = 19; }
		int def = (myNo < 10) ? 5 : 15;
		int fro[10], frn = 0, bac[10], bacn = 0;
		for (int i = aMin; i <= aMax; ++i) { if (!feBValid(i)) continue; if ((i >= 15 && i <= 19) || (i >= 5 && i <= 9)) fro[frn++] = i; else bac[bacn++] = i; }
		if (frn == 0 && bacn == 0) return def;
		for (int a = 1; a < frn; ++a) { int v = fro[a], b = a - 1; while (b >= 0 && !feCmpBattle(fro[b], v)) { fro[b + 1] = fro[b]; --b; } fro[b + 1] = v; }
		for (int a = 1; a < bacn; ++a) { int v = bac[a], b = a - 1; while (b >= 0 && !feCmpBattle(bac[b], v)) { bac[b + 1] = bac[b]; --b; } bac[b + 1] = v; }
		if (frn > 0) return fro[0]; return bac[0];
	}
	// ONE_ROW -> client wire row code (battleMenu.cpp): 0-4:26, 5-9:25, 10-14:23, 15-19:24; default enemy front row.
	static int feRowCode(int seed, int myNo) {
		if (seed >= 0 && seed <= 4) return 26; if (seed >= 5 && seed <= 9) return 25;
		if (seed >= 10 && seed <= 14) return 23; if (seed >= 15 && seed <= 19) return 24;
		return (myNo < 10) ? 24 : 25;
	}
	// fixCharTargetByMagicIndex (tcpserver 10506) -> client-native wire codes (battleMenu.cpp switch(magic.target)).
	static int feMagicFix(int mi, int seed, int myNo) {
		short mt = *(volatile short*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x0Au);
		switch (mt) {
		case 0: return myNo;                                                        // MYSELF
		case 1: return (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);    // OTHER (any single)
		case 2: return (myNo < 10) ? 20 : 21;                                       // ALLMYSIDE
		case 3: return (myNo < 10) ? 21 : 20;                                       // ALLOTHERSIDE
		case 4: return 22;                                                          // ALL
		case 5: return -1;                                                          // NONE
		case 6: return (seed == myNo) ? -1 : seed;                                  // OTHERWITHOUTMYSELF
		case 7: if (seed == myNo || seed == myNo + 5) return -1; return seed;        // WITHOUTMYSELFANDPET
		case 8: return (seed >= 0 && seed < 10) ? 20 : 21;                          // WHOLEOTHERSIDE (side of target)
		case 9: return (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);    // SINGLE
		case 10: return feRowCode((seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo), myNo); // ONE_ROW
		case 11: return (myNo < 10) ? 21 : 20;                                      // ALL_ROWS (all enemies)
		default: return (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);
		}
	}
	// fixCharTargetBySkillIndex (tcpserver 10679) -> client-native (battleMenu.cpp BATTLE_PROWAZA switch(skill.target)).
	static int feSkillFix(int si, int seed, int myNo) {
		short st = *(volatile short*)(0x0BD88168u + (unsigned int)si * 0xC0u + 0x04u);
		switch (st) {
		case 0: return myNo;                                                        // MYSELF
		case 2: return (myNo < 10) ? 20 : 21;                                       // ALLMYSIDE
		case 3: return (myNo < 10) ? 21 : 20;                                       // ALLOTHERSIDE
		case 4: return 22;                                                          // ALL
		case 5: return -1;                                                          // NONE
		case 8: return feRowCode((seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo), myNo); // ONE_ROW
		default: return (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);   // OTHER/single/line/death
		}
	}
	// Shared char-action decode for round/cross/normal rows. Faithful to selectRoundFun/intervalRoundFun
	// decode tail (tcpserver 8215-8304 / 8704-8793): tagetHash seed -> attack/magic/skill + MP gate.
	// Returns 1 = cmd written (fire this row); 0 = row does NOT fire (fall through to next priority).
	//   round/cross semantics: magic fix-fail or MP-fail => 0; skill fix-fail => 0; skill MP-fail => attack(1);
	//   attack invalid-seed => attack selectableEnemy(1); defense/escape => 1; seed unresolved => 0.
	static int feCharDecodeRC(int actionType, unsigned int tflags, int myNo, char* cmd, int* pjt) {
		*pjt = -2;
		if (actionType == 1) { cmd[0] = 'G'; cmd[1] = 0; return 1; }   // defense (sendBattleCharDefenseAct)
		if (actionType == 2) { cmd[0] = 'E'; cmd[1] = 0; return 1; }   // escape  (sendBattleCharEscapeAct)
		int seed = -1;
		if (tflags == 0x1u) seed = myNo;                          // kSelectSelf
		else if (tflags == 0x2u) seed = myNo + 5;                 // kSelectPet
		else if (tflags == 0x4u) seed = feSelectableAllie(myNo);  // kSelectAllieAny
		else if (tflags == 0x8u) seed = (myNo < 10) ? 20 : 21;    // kSelectAllieAll -> my side code
		else if (tflags == 0x10u) seed = feSelectableEnemy(myNo); // kSelectEnemyAny
		else if (tflags == 0x20u) seed = (myNo < 10) ? 21 : 20;   // kSelectEnemyAll -> enemy side code
		else if (tflags == 0x40u) seed = (myNo < 10) ? 24 : 25;   // kSelectEnemyFront -> enemy front-row code
		else if (tflags == 0x80u) seed = feSelectableBackFirst(myNo); // kSelectEnemyBack (owner EB) -> back-row-first single target
		else { for (int i = 10; i < 20; ++i) { if (tflags & (1u << i)) { seed = i - 10; break; } } }
		if (seed == -1) return 0;                                 // -1==tempTarget && no individual bit => break
		if (actionType == 0) {                                    // basic attack (sendBattleCharAttackAct)
			int at = (seed >= 0 && seed < 20) ? seed : feSelectableEnemy(myNo);
			wsprintfA(cmd, "H|%X", at); return 1;
		}
		const int mi = actionType - 3;
		const int charMp = *(volatile int*)(feBObj(myNo) + 0x84u);
		if (mi > 8) {                                             // profession/job skill (sendBattleCharJobSkillAct "P")
			const int si = mi - 9;
			const int t = feSkillFix(si, seed, myNo); *pjt = t;
			if (t < 0) return 0;                                  // fix-fail => fall through
			const int cost = *(volatile int*)(0x0BD88168u + (unsigned int)si * 0xC0u + 0xB8u);
			if (cost > charMp) { wsprintfA(cmd, "H|%X", feSelectableEnemy(myNo)); return 1; } // MP-fail => attack
			wsprintfA(cmd, "P|%X|%X", si, t); return 1;
		}
		const int t = feMagicFix(mi, seed, myNo); *pjt = t;       // magic (sendBattleCharMagicAct "J")
		if (t < 0) return 0;                                      // fix-fail => fall through
		const int cost = *(volatile int*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x04u);
		if (cost > charMp) return 0;                              // MP-fail => fall through (round/cross break)
		wsprintfA(cmd, "J|%X|%X", mi, t); return 1;
	}
	// ==== battle-tab char ROUND row (selectRoundFun 8177) + CROSS row (intervalRoundFun 8685) + delay(7235) ====
	static volatile LONG g_baCRRound = 0;   // kBattleCharRoundActionRoundValue (0=not use, else 1-based round)
	static volatile LONG g_baCREnemy = 0;   // kBattleCharRoundActionEnemyValue (0=not use, else enemies.size()>N)
	static volatile LONG g_baCRLevel = 0;   // kBattleCharRoundActionLevelValue (0=not use, else minLv>N*10)
	static volatile LONG g_baCRType = 0;    // kBattleCharRoundActionTypeValue (0 atk/1 def/2 esc/3+ magic/skill)
	static volatile LONG g_baCRTarget = 0;  // kBattleCharRoundActionTargetValue (kSelect* flags)
	static volatile LONG g_baCCEnable = 0;  // kBattleCrossActionCharEnable
	static volatile LONG g_baCCRound = 0;   // kBattleCharCrossActionRoundValue (interval = value+1)
	static volatile LONG g_baCCType = 0;    // kBattleCharCrossActionTypeValue
	static volatile LONG g_baCCTarget = 0;  // kBattleCharCrossActionTargetValue
	static volatile LONG g_baDelay = 0;     // kBattleActionDelayValue (ms; per-turn pre-action delay)
	static int g_baCrossCnt = 0;            // client-side battleCrossActionCounter_ (reset at battle start)
	static int g_baCrossFireLatch = 0;      // 1 on the round the cross counter matched (consumed this round)
	static int g_baCrossLastTurn = -1;      // svTurn of last cross-counter advance (advance once per round)
	static int g_baBatTurn = -1;            // svTurn tracker for battle-start (turn-backwards) counter reset
	static int g_baDelayTurn = -1;          // svTurn the per-turn delay timer was armed for
	static DWORD g_baDelayTick = 0;         // GetTickCount when delay timer armed
	// ==== battle-tab PET round (selectRound, BUG-FIXED keys) + cross (intervalRound, modulo) ====
	static volatile LONG g_baPRRound = 0; static volatile LONG g_baPREnemy = 0; static volatile LONG g_baPRLevel = 0;
	static volatile LONG g_baPRType = 0; static volatile LONG g_baPRTarget = 0;
	static volatile LONG g_baPCEnable = 0; static volatile LONG g_baPCRound = 0; static volatile LONG g_baPCType = 0; static volatile LONG g_baPCTarget = 0;
	// fePetSeed: launcher pet tagetHash (tcpserver 9505-9586), incl extended Leader/Teammate(+pet) via alliemin.
	static int fePetSeed(unsigned int tflags, int myNo, int alliemin) {
		if (tflags & 0x10u) return feSelectableEnemy(myNo);           // EnemyAny
		if (tflags & 0x20u) return 21;                                // EnemyAll (round literal 21 == TARGET_SIDE_LEFT)
		if (tflags & 0x40u) return (myNo < 10) ? 24 : 25;             // EnemyFront one-row
		if (tflags & 0x80u) return feSelectableBackFirst(myNo);      // EnemyBack (owner EB) -> back-row-first single target
		if (tflags & 0x1u)  return myNo;                              // Self
		if (tflags & 0x2u)  return myNo + 5;                          // Pet
		if (tflags & 0x4u)  return feSelectableAllie(myNo);           // AllieAny
		if (tflags & 0x8u)  return 20;                                // AllieAll (TARGET_SIDE_RIGHT)
		if (tflags & (1u<<10)) return alliemin + 0;                   // Leader
		if (tflags & (1u<<13)) return alliemin + 0 + 5;               // LeaderPet
		if (tflags & (1u<<11)) return alliemin + 1;                   // Teammate1
		if (tflags & (1u<<16)) return alliemin + 1 + 5;               // Teammate1Pet
		if (tflags & (1u<<12)) return alliemin + 2;                   // Teammate2
		if (tflags & (1u<<17)) return alliemin + 2 + 5;               // Teammate2Pet
		if (tflags & (1u<<14)) return alliemin + 3;                   // Teammate3
		if (tflags & (1u<<18)) return alliemin + 3 + 5;               // Teammate3Pet
		if (tflags & (1u<<15)) return alliemin + 4;                   // Teammate4
		if (tflags & (1u<<19)) return alliemin + 4 + 5;               // Teammate4Pet
		return -1;
	}
	// fePetFix: fixPetTargetBySkillIndex (tcpserver 10875) via petSkill[battlePetNoBak][si]@0xBD87220 (stride 742/106, target@+6).
	//   returns fixed target (>=0 send) or <0 (reject: OOB skill/pet, invalid skill, or type-7 exclusion).
	static int fePetFix(int skillIdx, int oldtarget, int myNo) {
		if (skillIdx < 0 || skillIdx >= 7) return -1;                 // >= MAX_PET_SKILL
		const int petNo = *(volatile int*)0x0056B8B0u;                // battlePetNoBak (acting pet)
		if (petNo < 0 || petNo >= 5) return -1;                       // MAX_PET
		const unsigned int ps = 0x0BD87220u + (unsigned int)petNo * 742u + (unsigned int)skillIdx * 106u;
		if (*(volatile short*)(ps + 0u) == 0) return -1;              // useFlag==0 (invalid)
		const short st = *(volatile short*)(ps + 6u);                 // PET_SKILL.target
		int t = oldtarget;
		switch (st) {
		case 0: t = myNo + 5; break;                                  // MYSELF
		case 2: t = (myNo < 10) ? 20 : 21; break;                     // ALLMYSIDE
		case 3: t = (oldtarget < 10) ? 20 : 21; break;                // ALLOTHERSIDE
		case 4: t = 22; break;                                        // ALL
		case 5: t = myNo + 5; break;                                  // NONE
		case 1: case 6: if (oldtarget < 0 || oldtarget >= 20) t = (myNo < 10) ? 19 : 9; break;   // OTHER/OTHERWITHOUTMYSELF
		case 8: case 11:                                              // ONE_ROW/ONE_ROW_ALL
			if (oldtarget >= 0 && oldtarget <= 4) t = 26; else if (oldtarget >= 5 && oldtarget <= 9) t = 25;
			else if (oldtarget >= 10 && oldtarget <= 14) t = 23; else if (oldtarget >= 15 && oldtarget <= 19) t = 24;
			else t = (myNo < 10) ? 24 : 25; break;
		case 7: { int mn, mx, row; if (myNo < 10) { mn = 0; mx = 19; row = 24; } else { mn = 10; mx = 19; row = 25; }   // WITHOUTMYSELFANDPET
			if (oldtarget < mn || oldtarget > mx) t = -1; else if (oldtarget == myNo + 5 || oldtarget == myNo) t = -1; else t = row; } break;
		default: break;                                               // ONE_LINE/DEATH/WHOLEOTHERSIDE: keep oldtarget
		}
		return t;
	}
	static volatile LONG g_baMHEnable = 0; static volatile LONG g_baMHTarget = 0; static volatile LONG g_baMHChar = 0; static volatile LONG g_baMHPet = 0; static volatile LONG g_baMHAllie = 0; static volatile LONG g_baMHMagic = 0; static volatile LONG g_baSkillMpEn = 0; static volatile LONG g_baSkillMpVal = 0; static volatile LONG g_baItemMpEn = 0; static volatile LONG g_baItemMpVal = 0; static volatile LONG g_walkDelay = 0;
	// battle-tab MAGIC HEAL (magicHealFun tcpserver 8313-8425). Client05 memory substrate (feBObj); issued via existing "J"/"P".
	//   launcher order self(checkCharHp useequal=false '<') -> pet(inline '<=' +alive) -> allie(checkAllieHp false '<').
	//   hp% = util::percent (floor, but >=1 if hp>0). status@0x90 DEAD=0x2 HIDE=0x200. MP gate = feCharDecodeRC cost tables.
	//   ride(mount)-heal branch (tcpserver 8334) omitted: this server/owner has no mount. magicIndex = g_baMHMagic-3 (same enc).
	static int feHpPct(int hp, int mx) { if (hp <= 0 || mx <= 0) return 0; int d = (int)((long long)hp * 100 / mx); if (d == 0) d = 1; return d; }
	static int feHealAlive(int pos) { unsigned int e = feBObj(pos); if (e == 0u) return 0; if (*(volatile int*)(e + 0x78u) <= 0) return 0; if (*(volatile int*)(e + 0x80u) <= 0) return 0; int st = *(volatile int*)(e + 0x90u); if (st & 0x2) return 0; if (st & 0x200) return 0; return 1; }
	static int feMagicHealRC(int myNo, char* cmd) {
		const unsigned int tf = (unsigned int)g_baMHTarget;
		const int charP = (int)g_baMHChar, petP = (int)g_baMHPet, allieP = (int)g_baMHAllie;
		int tgt = -1;
		if (tf & 0x1u) { unsigned int e = feBObj(myNo); if (e != 0u) { int hp = *(volatile int*)(e + 0x78u), mx = *(volatile int*)(e + 0x80u); if (mx > 0 && feHpPct(hp, mx) < charP) tgt = myNo; } }
		if (tgt < 0 && (tf & 0x2u)) { int pp = myNo + 5; if (feHealAlive(pp)) { unsigned int e = feBObj(pp); int hp = *(volatile int*)(e + 0x78u), mx = *(volatile int*)(e + 0x80u); if (feHpPct(hp, mx) <= petP) tgt = pp; } }
		if (tgt < 0 && (tf & 0xCu)) { int aMin, aMax; if (myNo < 10) { aMin = 0; aMax = 9; } else { aMin = 10; aMax = 19; } for (int i = aMin; i <= aMax; ++i) { if (!feHealAlive(i)) continue; unsigned int e = feBObj(i); int hp = *(volatile int*)(e + 0x78u), mx = *(volatile int*)(e + 0x80u); if (feHpPct(hp, mx) < allieP) { tgt = i; break; } } }
		if (tgt < 0) return 0;
		const int mi = (int)g_baMHMagic - 3;
		if (mi < 0) return 0;
		const int charMp = *(volatile int*)(feBObj(myNo) + 0x84u);
		if (mi > 8) { const int si = mi - 9; const int t = feSkillFix(si, tgt, myNo); if (t < 0) return 0; const int cost = *(volatile int*)(0x0BD88168u + (unsigned int)si * 0xC0u + 0xB8u); if (cost > charMp) return 0; wsprintfA(cmd, "P|%X|%X", si, t); return 1; }
		const int t = feMagicFix(mi, tgt, myNo); if (t < 0) return 0;
		const int cost = *(volatile int*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x04u);
		if (cost > charMp) return 0;
		wsprintfA(cmd, "J|%X|%X", mi, t); return 1;
	}
	static const UINT kNormalHealMsg = WM_APP + 0x1F1u;
	static volatile LONG g_nmhEnable = 0; static volatile LONG g_nmhChar = 0; static volatile LONG g_nmhMagic = 0; static volatile LONG g_nmhPet = 0; static volatile LONG g_nmhAllie = 0; static volatile LONG g_nmhIMpEn = 0; static volatile LONG g_nmhIMpVal = 0;
	// [NormalHeal] field magic-heal RC (F0 autoHeal 2439-2500 "平時精靈補血"): self->pet->ride->teammate.
	//   pc@0xBD770F8 hp+0x10/mx+0x14/mp+0x18/battlePetNo(short)+0xAA/ridePetNo(int)+0x5118/status+0xA4(PARTY0x200|LEADER0x100).
	//   pet[]@0xBD816D0 stride0xB78 hp+0x08/mx+0x0C/lv+0x20 ; party[]@0xBD85028 stride0x30 useFlag+0/lv+0x08/mx+0x0C/hp+0x10.
	//   magic[]@0xBD812E0 stride0x70 cost+0x04/target+0x0A. target self=0/pet=battlePetNo+1/ride=ridePetNo+1/teammate=idx+MAX_PET(5).
	static int feNMHPct(int hp, int mx) { if (mx <= 0) return -1; int p = (hp <= 0) ? 0 : (int)((long long)hp * 100 / mx); if (p == 0 && hp > 0) p = 1; return p; }
	static int feNormalMagicHealRC(int* pMi, int* pTarget) {
		const int charP = (int)g_nmhChar, petP = (int)g_nmhPet, allieP = (int)g_nmhAllie;
		if (charP <= 0 && petP <= 0 && allieP <= 0) return 0;
		int target = -1;
		if (charP > 0) { const int p = feNMHPct(*(volatile int*)0x0BD77108u, *(volatile int*)0x0BD7710Cu); if (p >= 0 && p < charP) target = 0; }
		if (target < 0 && petP > 0) { const int bpn = (int)*(volatile short*)(0x0BD770F8u + 0xAAu); if (bpn >= 0 && bpn < 5) { const unsigned int pb = 0x0BD816D0u + (unsigned int)bpn * 0xB78u; const int lv = *(volatile int*)(pb + 0x20u); const int p = feNMHPct(*(volatile int*)(pb + 0x08u), *(volatile int*)(pb + 0x0Cu)); if (lv > 0 && p >= 0 && p < petP) target = bpn + 1; } }
		if (target < 0 && petP > 0) { const int rpn = *(volatile int*)0x0BD7C210u; if (rpn >= 0 && rpn < 5) { const unsigned int pb = 0x0BD816D0u + (unsigned int)rpn * 0xB78u; const int lv = *(volatile int*)(pb + 0x20u); const int p = feNMHPct(*(volatile int*)(pb + 0x08u), *(volatile int*)(pb + 0x0Cu)); if (lv > 0 && p >= 0 && p < petP) target = rpn + 1; } }
		if (target < 0 && allieP > 0) { const unsigned int st = *(volatile unsigned int*)(0x0BD770F8u + 0xA4u); if ((st & 0x300u) != 0u) { for (int i = 0; i < 5; ++i) { const unsigned int qb = 0x0BD85028u + (unsigned int)i * 0x30u; if (*(volatile short*)(qb + 0x00u) == 0) continue; const int lv = *(volatile int*)(qb + 0x08u); const int p = feNMHPct(*(volatile int*)(qb + 0x10u), *(volatile int*)(qb + 0x0Cu)); if (lv > 0 && p >= 0 && p < allieP) { target = i + 5; break; } } } }
		if (target < 0) return 0;
		const int mi = (int)g_nmhMagic - 3; if (mi < 0 || mi > 8) return 0;
		const short mt = *(volatile short*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x0Au);
		if (mt != 0 && mt != 1) return 0;
		if (mt == 0 && target != 0) return 0;
		const int cost = *(volatile int*)(0x0BD812E0u + (unsigned int)mi * 0x70u + 0x04u);
		if (cost > *(volatile int*)0x0BD77110u) return 0;
		*pMi = mi; *pTarget = target; return 1;
	}
	// [ItemMp] MP회복 아이템 = 메모에 "기력"(CP949 B1E2B7C2) AND "회복"(C8B8BAB9) 둘 다 포함. pc.item[]@0xBD771BC stride0x17C useFlag@+0xDC memo@+0x114.
	static int feMemHas(const char* hay, const unsigned char* ndl, int nlen) {
		int hl = 0; while (hl < 84 && hay[hl] != '\0') ++hl;
		for (int i = 0; i + nlen <= hl; ++i) { int k = 0; for (; k < nlen; ++k) { if ((unsigned char)hay[i + k] != ndl[k]) break; } if (k == nlen) return 1; }
		return 0;
	}
	static int feFindMpItem() {
		static const unsigned char kwG[4] = { 0xB1u, 0xE2u, 0xB7u, 0xC2u };
		static const unsigned char kwH[4] = { 0xC8u, 0xB8u, 0xBAu, 0xB9u };
		for (int i = 0; i < 20; ++i) {
			const unsigned int ib = 0x0BD771BCu + (unsigned int)i * 0x17Cu;
			if (*(volatile short*)(ib + 0xDCu) == 0) continue;
			const char* mm = (const char*)(ib + 0x114u);
			if (feMemHas(mm, kwG, 4) && feMemHas(mm, kwH, 4)) return i;
		}
		return -1;
	}
	// [Battle SkillMp/ItemMp] F0 tcpserver actions 7/8. skill "成性"(CP949 E0F7E0F5) / item(memo 기력+회복). battle MP=feBObj+0x84, pc.maxMp@0xBD77114.
	static int feBattleSkillMpRC(int myNo, char* cmd) {
		const unsigned int e = feBObj(myNo); if (e == 0u) return 0;
		const int cur = *(volatile int*)(e + 0x84u);
		if (cur > (int)g_baSkillMpVal && cur > 0) return 0;
		static const unsigned char kwS[4] = { 0xE0u, 0xF7u, 0xE0u, 0xF5u };
		int si = -1;
		for (int i = 0; i < 30; ++i) { const unsigned int sb = 0x0BD88168u + (unsigned int)i * 0xC0u; if (*(volatile short*)(sb + 0x00u) == 0) continue; if (feMemHas((const char*)(sb + 0x08u), kwS, 4)) { si = i; break; } }
		if (si < 0) return 0;
		const int hp = *(volatile int*)0x0BD77108u, mx = *(volatile int*)0x0BD7710Cu; if (mx <= 0) return 0;
		if ((int)((long long)hp * 100 / mx) < 30) return 0;
		wsprintfA(cmd, "P|%X|%X", si, myNo); return 1;
	}
	static int feBattleItemMpRC(int myNo, char* cmd) {
		const unsigned int e = feBObj(myNo); if (e == 0u) return 0;
		const int cur = *(volatile int*)(e + 0x84u), mx = *(volatile int*)0x0BD77114u;
		if (mx <= 0) return 0; const int mpp = (cur <= 0) ? 0 : (int)((long long)cur * 100 / mx);
		if (mpp > (int)g_baItemMpVal) return 0;
		const int it = feFindMpItem(); if (it < 0) return 0;
		wsprintfA(cmd, "I|%X|%X", it, myNo); return 1;
	}
	// [MP-DUMP diag] one-shot: profession_skill[]@0xBD88168 stride0xC0 name@+8; pc.item[]@0xBD771BC stride0x17C name@+0xE6 memo@+0x114. CP949. offset/내용 확인용(읽기전용).
	static void feMpDump() {
		static DWORD s_mpd = 0u; const DWORD mpnow = GetTickCount(); if (s_mpd != 0u && (mpnow - s_mpd) < 3000u) return;
		const unsigned int sock = *(volatile unsigned int*)0x0BD71B90u;
		if (sock == 0u || sock == 0xFFFFFFFFu) return;
		s_mpd = mpnow;
		HANDLE h = CreateFileW(L"C:\\zmffk\\mpdump-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
		if (h == INVALID_HANDLE_VALUE) return;
		char b[600]; int n; DWORD w;
		n = wsprintfA(b, "==== MP-DUMP hp=%d/%d mp=%d/%d gold=%d bpn=%d (item=0BD771BC stride17C name+E6 memo+114) ====\r\n", *(volatile int*)0x0BD77108u, *(volatile int*)0x0BD7710Cu, *(volatile int*)0x0BD77110u, *(volatile int*)0x0BD77114u, *(volatile int*)0x0BD77158u, (int)*(volatile short*)0x0BD771A2u); WriteFile(h, b, (DWORD)n, &w, nullptr);
		for (int i = 0; i < 30; ++i) { const unsigned int sb = 0x0BD88168u + (unsigned int)i * 0xC0u; const short uf = *(volatile short*)(sb + 0x00u); const char* nm = (const char*)(sb + 0x08u); n = wsprintfA(b, "skill[%d] uf=%d name=%.40s\r\n", i, (int)uf, nm); WriteFile(h, b, (DWORD)n, &w, nullptr); }
		for (int i = 0; i < 20; ++i) { const unsigned int ib = 0x0BD771BCu + (unsigned int)i * 0x17Cu; const short uf = *(volatile short*)(ib + 0xDCu); const short tg = *(volatile short*)(ib + 0xE0u); const char* nm = (const char*)(ib + 0xE6u); const char* mm = (const char*)(ib + 0x114u); n = wsprintfA(b, "item[%d] uf=%d tgt=%d name=%.30s memo=%.84s\r\n", i, (int)uf, (int)tg, nm, mm); WriteFile(h, b, (DWORD)n, &w, nullptr); }
		CloseHandle(h);
	}
static const UINT kAutoWalkMsg = WM_APP + 0x1EFu;
static const UINT kFastBattleActMsg = WM_APP + 0x1F2u; // [FastBattleMsgFix] was 0x1F0u = collided with the exp-result window message (0x1F0). Moved to 0x1F2 so the RS-triggered exp message reaches the exp handler, not the fast-battle act handler.
static WNDPROC g_feOldWndProc = nullptr;
static HWND g_feHwnd = nullptr;
static DWORD g_fePid = 0u;
static int g_feOrigX = 0;
static int g_feOrigY = 0;
static int g_feOrigSet = 0;
static int g_awOrigX = 0;
static int g_awOrigY = 0;
static int g_awOrigSet = 0;
static LRESULT CALLBACK feWndProc(HWND fh, UINT fm, WPARAM fw, LPARAM fl)
{
	if (fm == kFeSendMsg)
	{
		const int fb = *(volatile int*)0x0064F83Cu;
		const unsigned int fs = *(volatile unsigned int*)0x0BD71B90u;
		if (fb == 0 && fs != 0u && fs != 0xFFFFFFFFu)
		{
			// fast-encounter (快速遇敵) — 런처 기전 = lssproto_W2_send in-place walk. [방향문자 확정: cnvServDir@0x45EC20
			// 디스어셈] a=北 b=東北 c=東 d=東南 e=南 f=西南 g=西 h=西北. 즉 런처의 "gcgc"=W,E,W,E 순수 카디널(상쇄).
			// 이 서버는 좌표를 (0,0) 대신 **현재타일(nowGx/nowGy)**로 보내야 걸음을 수락·상쇄한다(정상인 걷기조우 ③와 동일).
			// 지형(벽) 때문에 완전 상쇄가 안 되는 잔여 드리프트는 origin 방향으로 되돌리는 걸음으로 보정(같은 W2 걸음).
			const int cx = *(volatile int*)0x0BCDE0D8u;
			const int cy = *(volatile int*)0x0BCDE0DCu;
			// [FastEncFix 2026-08-07] pure in-place gcgc = launcher move(0,0,"gcgc") faithful. origin-capture + drift-correction
			// were an invention (not in launcher); a wrong origin (captured pre-login / mid-transition) made it walk-to-correct
			// forever -> drift + wall-jam + no encounter. gcgc (W,E,W,E) is net-zero in place so it CANNOT jam on a wall.
			// coords = current tile (this server requires it, see RULES). NO g_feOrig* used.
			char feDir[8]; feDir[0] = 'g'; feDir[1] = 'c'; feDir[2] = 'g'; feDir[3] = 'c'; feDir[4] = 0;
			// [FastEncFix2 2026-08-07] OPEN-TERRAIN test (cycle157) proved current-tile gcgc leaks on X (last-60 X span=11,
			// no walls) -> switch to launcher-faithful (0,0): lssproto_W2_send(p=(0,0),"gcgc") = move(QPoint(0,0),"gcgc") tcpserver 7133.
			// (0,0) = true in-place encounter roll (no coord walk -> no leak/drift). Gate on in-world (cx||cy != 0).
			if (cx != 0 || cy != 0) { ((void(__cdecl*)(int, int, int, char*))0x004B72E0u)((int)fs, 0, 0, feDir); }
		}
		return 0;
	}
	if (fm == kEscapeMsg)
	{
		// auto-escape (自動逃跑) — R0: 런처의 자동도주는 배틀 자동화 프레임워크(asyncBattleAction) 안에서만 돈다.
		// asyncBattleAction은 자동전투/빠른전투가 켜져야 진입하며 메뉴를 억제하고, playerDoBattleWork이
		// kAutoEscapeEnable을 제일 먼저 검사해 sendBattleCharEscapeAct("E")를 보낸다 — 게이트는 checkFlagState
		// (=내 차례, 아직 미행동). 이식: BattleMenuSuppressPatch를 autoEscape로 확장(메뉴 없는 진행) + "E"는
		// 반드시 **내 명령 차례**(BattleAnimFlag의 BattleMyNo 비트 clear)에만 송신 = 자동전투와 동일 게이트.
		const int eb = *(volatile int*)0x0064F83Cu;   // BattlingFlag
		const int ene = *(volatile int*)0x005A8080u;  // NoEscFlag
		const unsigned int es = *(volatile unsigned int*)0x0BD71B90u;  // sockfd
		const int emyNo = *(volatile int*)0x005A7E04u;   // BattleMyNo
		const int eanim = *(volatile int*)0x005A7E18u;   // BattleAnimFlag (acted bitmask)
		static DWORD s_aeSentTick = 0;
		const DWORD aeTick = GetTickCount();
		if (eb != 0 && ene == 0 && es != 0u && es != 0xFFFFFFFFu && emyNo >= 0 && emyNo < 20 && !(eanim & (1 << emyNo)) && (aeTick - s_aeSentTick) >= 700u)
		{
			*(volatile int*)0x0059DDE8u = 0;  // AI = AI_NONE (defensive)
			char eEsc[4] = { 'E', 0, 0, 0 };
			((void(__cdecl*)(int, char*))0x004B4BA0u)((int)es, eEsc);
			s_aeSentTick = aeTick;
		}
		return 0;
	}
	if (fm == kAutoWalkMsg)
	{
		// Native auto-walk (走路遇敵) — R0 re-port. Launcher mainthread.cpp:1922 = worker->move(current_pos, steps)
		// = lssproto_W2_send(sockfd, nowGx, nowGy, stepString) ("移動(封包)"). The step string is 4 side-flipping
		// groups of walk_len direction chars, so the char oscillates out-and-back (net-zero) accruing encounters.
		// Unlike fast-encounter's in-place (0,0)"gcgc", 走路遇敵 sends the REAL tile so the char physically walks.
		// wParam = walk_dir (0=E/W,1=N/S,2=random->E/W here), lParam = walk_len (clamped 1..6). W2@0x4B72E0.
		const int wb = *(volatile int*)0x0064F83Cu;
		const unsigned int ws = *(volatile unsigned int*)0x0BD71B90u;
		if (wb == 0 && ws != 0u && ws != 0xFFFFFFFFu)
		{
			// [F0] 런처 move(current_pos, steps): current_pos = autoWalk 진입 시 1회 캡처한 고정 원점(mainthread.cpp:1874).
			//   실시간 nowGx/nowGy를 매 전송 base로 넣던 것이 서남 드리프트 원인(잔여오차 누적) → 고정 원점(g_awOrig*)으로 복원.
			//   g_awOrigSet==0(캡처 전) 방어: 라이브 폴백. 정상 경로에선 모니터가 캡처 후에만 전송.
			const int wnx = g_awOrigSet ? g_awOrigX : *(volatile int*)0x0BCDE0D8u;
			const int wny = g_awOrigSet ? g_awOrigY : *(volatile int*)0x0BCDE0DCu;
			int wdir = (int)fw; int wlen = (int)fl;
			if (wlen < 1) wlen = 1; if (wlen > 6) wlen = 6;
			// [F0] 런처 走路遇敵 무변형 이식 (mainthread.cpp:1933-1986). 4그룹 × walk_len, 매 그룹 방향 토글,
			//   walk_dir==0: 'b'(東)/'f'(西), walk_dir==1: 'e'(南)/'a'(北); move(current_pos, steps) = W2(nowGx,nowGy).
			//   문자는 런처가 쓰는 그대로('b'/'f'/'a'/'e') — cnvServDir 근거로 'c'/'g'로 바꿨던 건 F0 위반(발명)이라 폐기.
			//   이동 거리는 오너의 走路距離 설정(walk_len)이 제어. 육안 이동은 이 구조에서 나옴.
			static int s_awSide = 0;
			char wsteps[32]; int wp = 0;
			for (int gi = 0; gi < 4; ++gi)
			{
				char dc;
				if (wdir == 1) dc = s_awSide ? 'e' : 'a';   // 南 : 北
				else           dc = s_awSide ? 'b' : 'f';   // 東 : 西
				s_awSide = s_awSide ? 0 : 1;                // 每次循環切換方向
				for (int j = 0; j < wlen && wp < 28; ++j) wsteps[wp++] = dc;
			}
			wsteps[wp] = 0;
			((void(__cdecl*)(int, int, int, char*))0x004B72E0u)((int)ws, wnx, wny, wsteps);
		}
		return 0;
	}
    if (fm == kExpResultMsg)
    {
        // [ExpResultHandler] 런처 Worker::lssproto_RS_recv(tcpserver 11802-11932) texts[] 이식:
        //   클라 battleResultMsg.resChr[]의 획득 exp를 "player exp:X ride exp:Y pet exp:Z"로 조합해
        //   클라 네이티브 채팅(StockChatBufferLine@0x00425490)에 출력. petNo -2=player / ridePetNo=ride / battlePetNo=pet.
        typedef void(__cdecl* ExpChatFn)(char*, unsigned char, int);
        ExpChatFn expChat = (ExpChatFn)0x00425490u;                 // StockChatBufferLine(str, pal, 0)
        const unsigned int brm = 0x0BD871A8u;                       // battleResultMsg (useFlag@0, resChr[i]@4+i*8)
        const int expRide = *(volatile int*)0x0BD7C210u;            // pc.ridePetNo (off 0x5118)
        const int expBattle = (int)*(volatile short*)0x0BD771A2u;   // pc.battlePetNo (off 0xAA)
        int exPlayer = 0, exRide = 0, exPet = 0;
        int lvPlayer = 0, lvRide = 0, lvPet = 0;                    // resChr[i].levelUp (>0 = 레벨업), petNo/ride/pet 별
        for (int ei = 0; ei < 5; ++ei)                              // RESULT_CHR_EXP = 5
        {
            const int ePetNo = (int)*(volatile short*)(brm + 4u + (unsigned int)ei * 8u);
            const int eLvUp = (int)*(volatile short*)(brm + 6u + (unsigned int)ei * 8u);  // levelUp @+6 (런처 token '|' idx2 >0)
            const int eExp = *(volatile int*)(brm + 8u + (unsigned int)ei * 8u);
            if (eExp <= 0) continue;                                // 런처: if (exp <= 0) continue
            if (ePetNo == -2) { exPlayer = eExp; lvPlayer = (eLvUp > 0) ? 1 : 0; }
            else if (ePetNo == expRide) { exRide = eExp; lvRide = (eLvUp > 0) ? 1 : 0; }
            else if (ePetNo == expBattle) { exPet = eExp; lvPet = (eLvUp > 0) ? 1 : 0; }
        }
        char eMsg[128];
        wsprintfA(eMsg, "player exp:%d%s ride exp:%d%s pet exp:%d%s", exPlayer, lvPlayer ? " [Lv UP]" : "", exRide, lvRide ? " [Lv UP]" : "", exPet, lvPet ? " [Lv UP]" : "");
        expChat(eMsg, (unsigned char)0u, 0);                        // FONT_PAL_WHITE = 0
        HANDLE eh = CreateFileW(L"C:\\zmffk\\autobattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (eh != INVALID_HANDLE_VALUE) { char eb[180]; int ebn = wsprintfA(eb, "exp-result %s (ride=%d battle=%d)\r\n", eMsg, expRide, expBattle); DWORD ebw = 0; WriteFile(eh, eb, (DWORD)ebn, &ebw, nullptr); CloseHandle(eh); }
        return 0;
    }

    if (fm == kNormalHealMsg)
    {
        // [NormalHealHandler+DIAG] field self-heal. F0: autoHeal magicHeal branch -> lssproto_MU_send(fd,x,y,magic,target).
        // Logs EVERY entry (not only on fire) so we can see WHY it didn't fire: en/bat/sock/hp%/mi/mt/cost/mp.
        const int nb = *(volatile int*)0x0064F83Cu;                     // BattlingFlag (0 = field / non-battle)
        const unsigned int ns = *(volatile unsigned int*)0x0BD71B90u;   // sockfd
        const int dhp = *(volatile int*)0x0BD77108u, dmx = *(volatile int*)0x0BD7710Cu;   // pc.hp / pc.maxHp
        int dpct = (dhp <= 0 || dmx <= 0) ? 0 : (int)((long long)dhp * 100 / dmx); if (dpct == 0 && dhp > 0) dpct = 1;
        const int dmi = (int)g_nmhMagic - 3;
        const short dmt = (dmi >= 0 && dmi <= 8) ? *(volatile short*)(0x0BD812E0u + (unsigned int)dmi * 0x70u + 0x0Au) : (short)-99;
        const int dcost = (dmi >= 0 && dmi <= 8) ? *(volatile int*)(0x0BD812E0u + (unsigned int)dmi * 0x70u + 0x04u) : -1;
        const int dmp = *(volatile int*)0x0BD77110u;                    // pc.mp
        int imp = -1, fImp = 0;
        if (g_nmhIMpEn != 0 && nb == 0 && ns != 0u && ns != 0xFFFFFFFFu)
        {
            const int cmp = *(volatile int*)0x0BD77110u, cmx = *(volatile int*)0x0BD77114u;   // pc.mp / pc.maxMp
            int mpp = (cmp <= 0 || cmx <= 0) ? 0 : (int)((long long)cmp * 100 / cmx); if (mpp == 0 && cmp > 0) mpp = 1;
            if (mpp < (int)g_nmhIMpVal)
            {
                imp = feFindMpItem();
                if (imp >= 0)
                {
                    const int ix = *(volatile int*)0x0BCDE0D8u, iy = *(volatile int*)0x0BCDE0DCu;
                    ((void(__cdecl*)(int,int,int,int,int))0x004B5C60u)((int)ns, ix, iy, imp, 0);   // lssproto_ID_send(fd,x,y,itemIndex,target=0) F0 autoHeal useItem
                    fImp = 1;
                }
            }
        }
        int mi = -1, tgt = -1, fired = 0;
        if (g_nmhEnable != 0 && nb == 0 && ns != 0u && ns != 0xFFFFFFFFu)
        {
            if (feNormalMagicHealRC(&mi, &tgt) == 1)
            {
                const int nx = *(volatile int*)0x0BCDE0D8u;             // nowGx
                const int ny = *(volatile int*)0x0BCDE0DCu;             // nowGy
                ((void(__cdecl*)(int,int,int,int,int))0x004B63A0u)((int)ns, nx, ny, mi, tgt);  // lssproto_MU_send(fd,x,y,magicIndex,target) F0 autoHeal useMagic
                fired = 1;
            }
        }
        HANDLE nhh = CreateFileW(L"C:\\zmffk\\normalheal-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (nhh != INVALID_HANDLE_VALUE) { char nbf[320]; int nn = wsprintfA(nbf, "nmh-handler en=%d bat=%d sock=%d hp=%d/mx%d pct=%d thr=%d petP=%d alP=%d mag=%d mi=%d mt=%d cost=%d mp=%d tgt=%d fired=%d impEn=%d impV=%d imp=%d fImp=%d\r\n", (int)g_nmhEnable, nb, (int)(ns != 0u && ns != 0xFFFFFFFFu), dhp, dmx, dpct, (int)g_nmhChar, (int)g_nmhPet, (int)g_nmhAllie, (int)g_nmhMagic, dmi, (int)dmt, dcost, dmp, tgt, fired, (int)g_nmhIMpEn, (int)g_nmhIMpVal, imp, fImp); DWORD nw = 0; WriteFile(nhh, nbf, (DWORD)nn, &nw, nullptr); CloseHandle(nhh); }
        return 0;
    }

    if (fm == kBattleActMsg)
    {
        // BattleActHandler: 自動戰鬥. Faithful re-port of Worker::handleCharBattleLogics NormalAction
        // (tcpserver.cpp 9190-9296) + helpers, driven by the launcher battle-tab channel fields, encoded
        // with the client's own battleMenu.cpp wire convention and sent via lssproto_B_send@0x4B4BA0.
        // Menu panel is code-patched away by BattleMenuSuppressPatch. See docs/battle-tab-spec.md.
        const int bbat = *(volatile int*)0x0064F83Cu;
        const unsigned int bfd = *(volatile unsigned int*)0x0BD71B90u;
        if (bbat == 0 || bfd == 0u || bfd == 0xFFFFFFFFu) return 0;
        const int myNo = *(volatile int*)0x005A7E04u;
        if (myNo < 0 || myNo >= 20) return 0;
        *(volatile int*)0x0059DDE8u = 0; // AI = AI_NONE (defensive; menu handler code-patched away separately).
        const int animFlag = *(volatile int*)0x005A7E18u;
        const int svTurn = *(volatile int*)0x005A7E24u;
        typedef void(__cdecl* BattleSendFn)(int, char*);
        BattleSendFn baSend = (BattleSendFn)0x004B4BA0u;
        const int charBit = 1 << myNo;
        const int petPos = myNo + 5;
        const int petBit = (petPos < 31) ? (1 << petPos) : 0;
        int eMin, eMax; if (myNo < 10) { eMin = 10; eMax = 19; } else { eMin = 0; eMax = 9; }
        const DWORD baTick = GetTickCount();
        // [BC-CAPTURE / fast-fight groundwork] BattleStatus is a char[] at 0x5A2DF8 (verified in set_bc:
        //   cmp byte[idx+0x5a2df8]). Dump the raw BC packet text once per svTurn (normal mode, zero client impact)
        //   to lock the exact per-server BC format before writing the native (8001-style) BC parser.
        {
            static int s_bcTurn = -999;
            if (svTurn != s_bcTurn) {
                s_bcTurn = svTurn;
                const char* bs = (const char*)0x005A2DF8u;
                if (bs[0] != 0) {
                    HANDLE ch = CreateFileW(L"C:\\zmffk\\bc-capture.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
                    if (ch != INVALID_HANDLE_VALUE) {
                        char hdr[48]; int hn = wsprintfA(hdr, "== turn=%d ==\r\n", svTurn); DWORD w = 0;
                        WriteFile(ch, hdr, (DWORD)hn, &w, nullptr);
                        int bl = lstrlenA(bs); if (bl > 700) bl = 700;
                        WriteFile(ch, bs, (DWORD)bl, &w, nullptr);
                        WriteFile(ch, "\r\n", 2, &w, nullptr);
                        CloseHandle(ch);
                    }
                }
            }
        }
        // ===== client/server turn resync (recovery only; NO send-gating). Keep cli aligned to the authoritative
        //   server turn so CheckBattleAnimFlag never deadlocks, WITHOUT delaying our sends:
        //     cli>sv  = battle-start overshoot -> snap to sv now
        //     gap>=2  = large desync (the original stall) -> snap now
        //     cli<sv & afl==0 = no animation for the client to self-advance on -> snap now
        //   cli<sv & afl!=0 is the NORMAL 1-turn animation lag (client will cli++ itself) -> leave it, do NOT gate. =====
        int cliTurn = *(volatile int*)0x005A7E20u;
        if (cliTurn != svTurn && (cliTurn > svTurn || (svTurn - cliTurn) >= 2 || animFlag == 0)) {
            *(volatile int*)0x005A7E20u = svTurn; cliTurn = svTurn;
        }
        // ===== character action. Gate on cli==sv: only send when the client has settled at the turn's input point.
        //   Sending while cli!=sv (mid animation/transition) over-drives the client and stalls it at SubProcNo=2.
        //   The cli>sv battle-start overshoot is snapped to sv above, so this gate does NOT cause a first-turn wait. =====
        if (!(animFlag & charBit) && cliTurn == svTurn && (baTick - g_baCharSentTick) >= 700u)
        {
            char bcmd[24];
            const int fallback = feSelectableEnemy(myNo); // tcpserver 9296 final fallback (sendBattleCharAttackAct).
            // [자동도주] playerDoBattleWork(tcpserver 7379)처럼 자동도주가 켜졌으면 배틀탭 액션보다 먼저 도주.
            //   내턴 게이트(위)+700ms 디바운스는 자동전투와 공유. NoEscFlag!=0(도주불가)면 기본공격으로 턴 진행.
            // [낙마도주 fallDownEscapeFun tcpserver 7998, 최우선] onRide(p_party[myNo]+0x194): >0 라이딩, <=0 난마. 난마 시 도주.
            const int bcRide0 = feBCRideFlag(myNo);   // BC packet rideFlag: 1=riding, 0=fell(=난마), -1=unknown. (launcher fallDownEscapeFun)
            const int fellOff0 = (g_baFallEscape && bcRide0 == 0) ? 1 : 0;   // escape ONLY when definitively fell (rideFlag==0), like launcher
            if (g_baAutoEscape || fellOff0) {
                if (*(volatile int*)0x005A8080u == 0) { // NoEscFlag==0 (escape allowed)
                    bcmd[0] = 'E'; bcmd[1] = 0; baSend((int)bfd, bcmd);
                    // belt-and-suspenders: if the manual command menu is showing (battleMenuFlag!=0),
                    // replicate the client-native escape-button state so the menu dismisses & the turn advances,
                    // even if BattleMenuSuppressPatch didn't take. (battleMenu.cpp:2010 BattleButtonEscape)
                    if (*(volatile int*)0x005A7E48u != 0) { ((void(__cdecl*)(void))0x00418900u)(); *(volatile int*)(0x005A7E58u + 28u) = 1; *(volatile int*)0x005A7E38u = 1; *(volatile int*)0x005A7F18u = 1; }
                } else { wsprintfA(bcmd, "H|%X", fallback); baSend((int)bfd, bcmd); }
                g_baCharSentTick = baTick; { HANDLE eh = CreateFileW(L"C:\\zmffk\\autobattle-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (eh != INVALID_HANDLE_VALUE) { char ebf[160]; int ebn = wsprintfA(ebf, "autobattle ESCAPE turn=%d myNo=%d ride=%d fell=%d ae=%d noEsc=%d\r\n", svTurn, myNo, bcRide0, fellOff0, (int)g_baAutoEscape, *(volatile int*)0x005A8080u); DWORD ebw = 0; WriteFile(eh, ebf, (DWORD)ebn, &ebw, nullptr); CloseHandle(eh); } } return 0; }
            // [S1] valid-enemy count + min level over enemy side (launcher bt.enemies valid criteria).
            int validCnt = 0; int minLv = 0x7fffffff;
            for (int i = eMin; i <= eMax; ++i) { if (!feBValid(i)) continue; ++validCnt; int lv = *(volatile int*)(feBObj(i) + 0x8Cu); if (lv < minLv) minLv = lv; }
            if (validCnt == 0) return 0; // turn-0 race: enemy actors not loaded yet -> defer to next tick.
            // [S-reset] battle-start reset (launcher battleCrossActionCounter_.reset() at lssproto_EN_recv 13513):
            //   svTurn going backwards = a new battle -> reset cross-action counter + per-turn delay arming.
            if (svTurn < g_baBatTurn) { g_baCrossCnt = 0; g_baCrossFireLatch = 0; g_baCrossLastTurn = -1; g_baDelayTurn = -1; }
            g_baBatTurn = svTurn;
            // [S0] battle delay (kBattleActionDelayValue, tcpserver playerDoBattleWork 7232): launcher msleeps
            //   `delay` ms before handleCharBattleLogics each round. We can't block the client main thread, so
            //   gate the send on elapsed time since this turn became actionable (armed once per svTurn).
            const unsigned int delayMs = (unsigned int)g_baDelay;
            if (delayMs > 0)
            {
                if (g_baDelayTurn != svTurn) { g_baDelayTurn = svTurn; g_baDelayTick = baTick; return 0; }
                if ((baTick - g_baDelayTick) < delayMs) return 0;
            }
            // ===== priority chain (handleCharBattleLogics 9144-9296): selectRound(4) > intervalRound(10) > normal > fallback =====
            int rowFired = 0; int usedRow = 9; int usedType = -1; unsigned int usedTflags = 0u; int jt = -2;
            // --- [Row 4] selectRoundFun (tcpserver 8177-8308): fire on the configured round if gates pass ---
            do {
                const int rr = (int)g_baCRRound;                 // 0=not use, else 1-based "at round N"
                if (rr <= 0) break;
                if (rr != svTurn + 1) break;                     // battleCurrentRound == serverRound+1 == svTurn+1
                const int re = (int)g_baCREnemy; if (re != 0 && validCnt <= re) break;   // enemies.size() must be > re
                const int rl = (int)g_baCRLevel; if (rl != 0 && minLv <= rl * 10) break; // minLevel must be > rl*10
                if (feCharDecodeRC((int)g_baCRType, (unsigned int)g_baCRTarget, myNo, bcmd, &jt) == 1)
                { usedRow = 4; usedType = (int)g_baCRType; usedTflags = (unsigned int)g_baCRTarget; baSend((int)bfd, bcmd); rowFired = 1; }
            } while (0);
            // --- [Row 5] magicHealFun (tcpserver 8313-8425): heal self->pet->allie by hp%% threshold BEFORE attack ---
            if (!rowFired && g_baMHEnable != 0 && feMagicHealRC(myNo, bcmd) == 1)
            { usedRow = 5; usedType = (int)g_baMHMagic; usedTflags = (unsigned int)g_baMHTarget; baSend((int)bfd, bcmd); rowFired = 1; }
            // [Row 7] skillMp (嗜血補氣 tcpserver actions.insert 7): battle MP <= threshold -> job skill "成性" self
            if (!rowFired && g_baSkillMpEn != 0 && feBattleSkillMpRC(myNo, bcmd) == 1)
            { usedRow = 7; baSend((int)bfd, bcmd); rowFired = 1; }
            // [Row 8] itemMp (道具補氣 tcpserver actions.insert 8): battle MP% <= threshold -> item(memo 기력+회복) self
            if (!rowFired && g_baItemMpEn != 0 && feBattleItemMpRC(myNo, bcmd) == 1)
            { usedRow = 8; baSend((int)bfd, bcmd); rowFired = 1; }
            // --- [Row 10] intervalRoundFun (tcpserver 8685-8797): reached only if round did not fire ---
            if (!rowFired && g_baCCEnable != 0)
            {
                const int crRound = (int)g_baCCRound + 1;        // interval = kBattleCharCrossActionRoundValue + 1
                if (svTurn != g_baCrossLastTurn)                 // advance the counter once per round
                {
                    g_baCrossLastTurn = svTurn;
                    if (g_baCrossCnt < crRound) { g_baCrossCnt++; g_baCrossFireLatch = 0; }
                    else { g_baCrossCnt = 0; g_baCrossFireLatch = 1; }
                }
                if (g_baCrossFireLatch && feCharDecodeRC((int)g_baCCType, (unsigned int)g_baCCTarget, myNo, bcmd, &jt) == 1)
                { usedRow = 10; usedType = (int)g_baCCType; usedTflags = (unsigned int)g_baCCTarget; baSend((int)bfd, bcmd); rowFired = 1; }
            }
            // --- [Normal row] (tcpserver 9190-9296): reached if neither round nor cross fired ---
            if (!rowFired)
            {
                const int enemyVal = (int)g_baCharEnemy;
                const int levelVal = (int)g_baCharLevel;
                int condMet = 1;
                if (enemyVal > 0 && validCnt <= enemyVal) condMet = 0;   // enemies.size() <= enemy => fallback attack
                if (levelVal > 0 && minLv <= levelVal * 10) condMet = 0; // minLevel <= level*10 => fallback attack
                if (condMet && feCharDecodeRC((int)g_baCharType, (unsigned int)g_baCharTarget, myNo, bcmd, &jt) == 1)
                { usedRow = 0; usedType = (int)g_baCharType; usedTflags = (unsigned int)g_baCharTarget; }
                else { usedRow = -1; wsprintfA(bcmd, "H|%X", fallback); } // final fallback: sendBattleCharAttackAct(getBattleSelectableEnemyTarget)
                baSend((int)bfd, bcmd);
                rowFired = 1;
            }
            g_baCharSentTick = baTick;
            // [StallDiag] 각 적 pos의 사망판정 후보 필드 전부 덤프 — 멈춤 시 죽은 적이 어느 필드로 표시되는지 실측.
            //   st=status@0x90, hp=@0x78, mx=maxHp@0x80, df=deathFlag@0x24, fn=func@0x8, lv=level@0x8C, v=feBValid.
            char estr[480]; int esn = 0; estr[0] = 0;
            for (int es = eMin; es <= eMax; ++es) { unsigned int eo = feBObj(es); if (eo == 0u) continue; int est = *(volatile int*)(eo + 0x90u); int eh = *(volatile int*)(eo + 0x78u); int emx = *(volatile int*)(eo + 0x80u); int edf = *(volatile int*)(eo + 0x24u); unsigned int efn = *(volatile unsigned int*)(eo + 0x8u); int elv = *(volatile int*)(eo + 0x8Cu); int ev = feBValid(es); if (esn < 430) esn += wsprintfA(estr + esn, "%d:st%X/hp%d/mx%d/df%d/fn%X/lv%d/v%d ", es, est, eh, emx, edf, efn, elv, ev); }
            // [StallDiag2] 원시 배틀상태 + 상태머신 위치(SubProcNo/action_inf/ProcNo/menuFlag/targetSel) — turn 진행 정지 지점 실측.
            const int resWnd = *(volatile int*)0x005A7E28u;
            const unsigned int subP = *(volatile unsigned int*)0x0BD8954Cu; const unsigned int procN = *(volatile unsigned int*)0x0BD89548u;
            const int actInf = *(volatile int*)0x0D6AEAF0u; const int menuF = *(volatile int*)0x005A7E48u; const int tgtSel = *(volatile int*)0x005A7F24u;
            const unsigned int selfObj = feBObj(myNo); const unsigned int petObj = feBObj(myNo + 5);
            const int selfHp = selfObj ? *(volatile int*)(selfObj + 0x78u) : -1; const int selfSt = selfObj ? *(volatile int*)(selfObj + 0x90u) : -1;
            const int petHp = petObj ? *(volatile int*)(petObj + 0x78u) : -1; const int petSt = petObj ? *(volatile int*)(petObj + 0x90u) : -1;
            const int selfMx = selfObj ? *(volatile int*)(selfObj + 0x80u) : 0; const int petMx = petObj ? *(volatile int*)(petObj + 0x80u) : 0;
            const int selfPct = feHpPct(selfHp, selfMx); const int petPct = feHpPct(petHp, petMx);
            HANDLE bh = CreateFileW(L"C:\\zmffk\\autobattle-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (bh != INVALID_HANDLE_VALUE) { char bb[900]; int bn = wsprintfA(bb, "autobattle CHAR t=%u turn=%d cliT=%d myNo=%d afl=%X cb=%d pb=%d subP=%u procN=%u actInf=%d menuF=%X tgtSel=%d resW=%d self=hp%d/st%X pet=hp%d/st%X validEnemy=%d fallback=%d delay=%u cmd=%s heal[en=%d tf=%X c=%d p=%d a=%d mag=%d selfP=%d/mx%d petP=%d/mx%d] | enemies=%s\r\n", baTick, svTurn, cliTurn, myNo, animFlag, (animFlag & charBit) ? 1 : 0, (animFlag & petBit) ? 1 : 0, subP, procN, actInf, menuF, tgtSel, resWnd, selfHp, selfSt, petHp, petSt, validCnt, fallback, delayMs, bcmd, (int)g_baMHEnable, (unsigned int)g_baMHTarget, (int)g_baMHChar, (int)g_baMHPet, (int)g_baMHAllie, (int)g_baMHMagic, selfPct, selfMx, petPct, petMx, estr); DWORD bw = 0; WriteFile(bh, bb, (DWORD)bn, &bw, nullptr); CloseHandle(bh); }
            return 0;
        }
        // ===== pet action (char acted + my pet BattleAnimFlag bit clear) =====
        // handlePetBattleLogics(tcpserver 9300-9718) priority: SelectedRound(4) > CrossRound(10) > Normal.
        // NOTE(의도적 편차): 런처 원본 SelectedRound(9471/9481/9490)에는 복붙 버그 3개가 있다 -
        //   (1) 라운드 지정값을 Enemy 해시에서, (2) 적수 게이트를 Level 해시에서, (3) 레벨 게이트를 Char 해시에서
        //   읽는다. 오너 지시("버그 수정 후 빌드")에 따라 아래 매핑은 Round/Enemy/Level 해시로 바로잡아 포팅했다.
        //   (매핑 교정은 mainthread baPetReapply/baPetEdge 단계에서 이미 반영됨.)
        //   미포팅 편차: sendBattlePetSkillAct의 補血(회복스킬 적 대상금지) 가드는 petSkill.memo 문자열 매칭이 필요해 생략.
        if ((animFlag & charBit) && petBit != 0 && !(animFlag & petBit) && cliTurn == svTurn && (baTick - g_baPetSentTick) >= 700u)
        {
            char pcmd[24];
            // 자동도주 시 펫은 별도 도주명령이 없으므로 아무것도 안 함(W|FF|FF)으로 턴만 진행.
            if (g_baAutoEscape) { pcmd[0]='W'; pcmd[1]='|'; pcmd[2]='F'; pcmd[3]='F'; pcmd[4]='|'; pcmd[5]='F'; pcmd[6]='F'; pcmd[7]=0; baSend((int)bfd, pcmd); g_baPetSentTick = baTick; return 0; }
            const int petUi = svTurn + 1;              // battleCurrentRound == serverRound+1
            const int alliemin = (myNo < 10) ? 0 : 10; // bt.alliemin
            int pValid = 0; int pMinLv = 0x7fffffff;
            for (int i = eMin; i <= eMax; ++i) { if (!feBValid(i)) continue; ++pValid; int lv = *(volatile int*)(feBObj(i) + 0x8Cu); if (lv < pMinLv) pMinLv = lv; }
            int petRow = 0; int petSkillIdx = -1; int petTarget = -2; int petSeed = -2;
            // --- [Pet Row 4] SelectedRound (9467-9598): 버그수정 매핑 (Round/Enemy/Level) ---
            do {
                const int rr = (int)g_baPRRound;                                   // 지정 라운드 (1-based)
                if (rr <= 0) break;
                if (rr != petUi) break;
                const int re = (int)g_baPREnemy; if (re != 0 && pValid <= re) break;                    // enemies.size() > re
                const int rl = (int)g_baPRLevel; if (rl != 0 && pMinLv != 0x7fffffff && pMinLv <= rl * 10) break; // minLevel > rl*10
                const int si = (int)g_baPRType; if (si < 0 || si >= 7) break;      // skillIndex < MAX_PET_SKILL
                petSeed = fePetSeed((unsigned int)g_baPRTarget, myNo, alliemin);
                const int t = fePetFix(si, petSeed, myNo);
                if (t >= 0) { petRow = 4; petSkillIdx = si; petTarget = t; wsprintfA(pcmd, "W|%X|%X", si, t); baSend((int)bfd, pcmd); }
            } while (0);
            // --- [Pet Row 10] CrossRound (9603-9718): enable + (battleCurrentRound % (round+1))==0, 폴백 포함 ---
            if (petRow == 0 && g_baPCEnable != 0)
            {
                do {
                    const int crR = (int)g_baPCRound + 1; if (crR <= 0) break;
                    if ((petUi % crR) != 0) break;
                    const int si = (int)g_baPCType; if (si < 0 || si >= 7) break;
                    petSeed = fePetSeed((unsigned int)g_baPCTarget, myNo, alliemin);
                    int t = fePetFix(si, petSeed, myNo);
                    if (t < 0) { petSeed = feSelectableEnemy(myNo); t = fePetFix(si, petSeed, myNo); } // 9710-9716 폴백
                    if (t >= 0) { petRow = 10; petSkillIdx = si; petTarget = t; wsprintfA(pcmd, "W|%X|%X", si, t); baSend((int)bfd, pcmd); }
                } while (0);
            }
            // --- [Pet Row 0] Normal (기존 동작 유지): g_baPetType>=0 -> W|type|selectableEnemy, else W|FF|FF ---
            if (petRow == 0)
            {
                const int ptype = (int)g_baPetType;
                if (ptype >= 0) { int pt = feSelectableEnemy(myNo); petSkillIdx = ptype; petTarget = pt; wsprintfA(pcmd, "W|%X|%X", ptype, pt); }
                else { pcmd[0]='W'; pcmd[1]='|'; pcmd[2]='F'; pcmd[3]='F'; pcmd[4]='|'; pcmd[5]='F'; pcmd[6]='F'; pcmd[7]=0; petSkillIdx = -1; petTarget = -1; }
                baSend((int)bfd, pcmd);
            }
            g_baPetSentTick = baTick;
            HANDLE ph = CreateFileW(L"C:\\zmffk\\autobattle-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (ph != INVALID_HANDLE_VALUE) { char pb[240]; int pn = wsprintfA(pb, "autobattle PET turn=%d myNo=%d row=%d si=%d seed=%d target=%d validEnemy=%d minLv=%d pcEnable=%d cmd=%s\r\n", svTurn, myNo, petRow, petSkillIdx, petSeed, petTarget, pValid, (pMinLv == 0x7fffffff ? -1 : pMinLv), (int)g_baPCEnable, pcmd); DWORD pw = 0; WriteFile(ph, pb, (DWORD)pn, &pw, nullptr); CloseHandle(ph); }
            return 0;
        }
        return 0;
    }
    return g_feOldWndProc != nullptr ? CallWindowProcW(g_feOldWndProc, fh, fm, fw, fl) : DefWindowProcW(fh, fm, fw, fl);
}
static BOOL CALLBACK feFindWnd(HWND fh, LPARAM)
{
	DWORD wpid = 0u; GetWindowThreadProcessId(fh, &wpid);
	if (wpid == g_fePid && GetWindow(fh, GW_OWNER) == nullptr && IsWindowVisible(fh) != FALSE) { g_feHwnd = fh; return FALSE; }
	return TRUE;
}
// [FastBattleHook stage1] inline-hook lssproto_EN_recv(0x485200)/lssproto_B_recv(0x483BF0) to LOG raw
// packet args (call-through, NO block/drive yet) so the real BP/BA/BC wire format is captured before we
// port the launcher's parser+driver. Prologue of both = 10 bytes (55 8bec + cmp[abs],0) with NO relative
// operand, so a 10-byte copy trampoline + 5-byte E9 detour is safe. void __cdecl -> args on stack as-is.
typedef void (__cdecl* t_fbEN)(int fd, int result, int field);
typedef void (__cdecl* t_fbB)(int fd, char* command);
static t_fbEN g_fbTrampEN = nullptr;
static t_fbB  g_fbTrampB  = nullptr;
static volatile LONG g_fbLogEn = 0;
// [FoundationAShadow] wire-parse battle state (launcher Worker::lssproto_B_recv port) and VERIFY it against
// the client SCENE memory the existing auto-battle driver reads. SHADOW ONLY: parse + compare-log, no block, no send.
// BC wire (from Stage1 capture): BC|attr|<unit0..>; unit i fields at full-token base 2+i*13: pos+0 level+4 hp+5 maxhp+6 status+7.
struct FbState { volatile LONG active; int myPos; int myMp; int turn; int animFlag; int hp[20]; int maxhp[20]; int status[20]; int level[20]; int present[20]; int modelid[20]; int rideFlag[20]; int rideLevel[20]; int rideHp[20]; int rideMaxHp[20]; char name[20][32]; char rideName[20][32]; }; // [FastBattleBCParse cycle172] fields ported 1:1 from launcher tcpserver.cpp lssproto_B_recv case 'C' battle_object_t (name/modelid/rideFlag/ride*)
static FbState g_fb = {};
static volatile LONG g_fbHadEnemy = 0; // [FastBattleHadEnemy] set once we've parsed a live enemy this battle; reset on EN. Guards conclusion so a battle-start/partial BC (no enemies yet) is not mistaken for "all dead".
static void fbHookLog(const char* s);  // fwd-decl: fbParseBC (conclusion) + fbShadowB log before fbHookLog's definition below
static int fbTok(const char* s, int n, char* out, int cap) {
	int idx = 0; const char* p = s;
	while (*p && idx < n) { if (*p == '|') idx++; p++; }
	int oi = 0; if (idx < n) { if (cap > 0) out[0] = 0; return 0; }
	while (*p && *p != '|' && oi < cap - 1) { out[oi++] = *p++; }
	out[oi] = 0; return oi;
}
static int fbHex(const char* s) {
	int v = 0, neg = 0; const char* p = s; if (*p == '-') { neg = 1; p++; }
	while (*p) { char c = *p++; int d; if (c >= '0' && c <= '9') d = c - '0'; else if (c >= 'a' && c <= 'f') d = c - 'a' + 10; else if (c >= 'A' && c <= 'F') d = c - 'A' + 10; else break; v = v * 16 + d; }
	return neg ? -v : v;
}
static void fbParseBC(const char* cmd) {
	// [FastBattleBCParse cycle172] launcher-faithful port of Worker::lssproto_B_recv case 'C' (tcpserver.cpp 13957~14024).
	// Per-unit block = 13 tokens; launcher reads at i*13+2..i*13+14. Our token base = 2 + i*13 (== i*13+2), so:
	//   base+0 pos | base+1 name | base+2 freeName(skip) | base+3 modelid | base+4 level | base+5 hp | base+6 maxHp |
	//   base+7 status | base+8 rideFlag | base+9 rideName | base+10 rideLevel | base+11 rideHp | base+12 rideMaxHp.
	// Note: DEAD-zeroing + valid() (needs sa::BC_FLG_DEAD/HIDE) are launcher CONSUMER-side steps -> ported in cycle C (data-source swap). Here we capture raw fields only.
	for (int i = 0; i < 20; ++i) g_fb.present[i] = 0;
	char tk[64];
	for (int i = 0; i < 20; ++i) {
		int base = 2 + i * 13;
		if (fbTok(cmd, base, tk, sizeof(tk)) == 0) break;
		int pos = fbHex(tk); if (pos < 0 || pos >= 20) break;
		fbTok(cmd, base + 1, g_fb.name[pos], 32);                    // +3 name (raw token; makeStringFromEscaped deferred to consumer)
		fbTok(cmd, base + 3, tk, sizeof(tk)); int mid = fbHex(tk);   // +5 modelid
		fbTok(cmd, base + 4, tk, sizeof(tk)); int lv = fbHex(tk);    // +6 level
		fbTok(cmd, base + 5, tk, sizeof(tk)); int hp = fbHex(tk);    // +7 hp
		fbTok(cmd, base + 6, tk, sizeof(tk)); int mx = fbHex(tk);    // +8 maxHp
		fbTok(cmd, base + 7, tk, sizeof(tk)); int st = fbHex(tk);    // +9 status
		fbTok(cmd, base + 8, tk, sizeof(tk)); int rf = fbHex(tk);    // +10 rideFlag
		fbTok(cmd, base + 9, g_fb.rideName[pos], 32);                // +11 rideName
		fbTok(cmd, base + 10, tk, sizeof(tk)); int rlv = fbHex(tk);  // +12 rideLevel
		fbTok(cmd, base + 11, tk, sizeof(tk)); int rhp = fbHex(tk);  // +13 rideHp
		fbTok(cmd, base + 12, tk, sizeof(tk)); int rmx = fbHex(tk);  // +14 rideMaxHp
		g_fb.present[pos] = 1; g_fb.level[pos] = lv; g_fb.hp[pos] = hp; g_fb.maxhp[pos] = mx; g_fb.status[pos] = st;
		g_fb.modelid[pos] = mid; g_fb.rideFlag[pos] = rf; g_fb.rideLevel[pos] = rlv; g_fb.rideHp[pos] = rhp; g_fb.rideMaxHp[pos] = rmx;
	}
}
static volatile LONG g_fbActedTurn = -999;
static void fbShadowEN(int result, int field) { (void)field; g_fb.active = (result > 0) ? 1 : 0; if (result > 0) { g_fbActedTurn = -999; g_fbHadEnemy = 0; for (int i = 0; i < 20; ++i) { g_fb.present[i] = 0; g_fb.hp[i] = 0; } } }
static void fbShadowB(char* command) {
	if (command == nullptr || command[0] == 0 || command[1] == 0) return;
	char tk[32];
	switch (command[1]) {
	case 'C': fbParseBC(command); if (g_fbLogEn) { for (int p = 0; p < 20; ++p) { if (g_fb.present[p]) { char lb[192]; wsprintfA(lb, "BCunit pos=%d model=%X lv=%d hp=%d/%d st=%X rf=%d rlv=%d rhp=%d/%d name=%s ride=%s\r\n", p, g_fb.modelid[p], g_fb.level[p], g_fb.hp[p], g_fb.maxhp[p], g_fb.status[p], g_fb.rideFlag[p], g_fb.rideLevel[p], g_fb.rideHp[p], g_fb.rideMaxHp[p], g_fb.name[p], g_fb.rideName[p]); fbHookLog(lb); } } } break; // [FastBattleBCParse cycle172] deterministic parse-log: verify g_fb captured every case 'C' field vs the raw "B ... head=" wire dump
	case 'A': fbTok(command, 1, tk, sizeof(tk)); g_fb.animFlag = fbHex(tk); fbTok(command, 2, tk, sizeof(tk)); g_fb.turn = fbHex(tk); break;
	case 'P': fbTok(command, 1, tk, sizeof(tk)); g_fb.myPos = fbHex(tk); fbTok(command, 3, tk, sizeof(tk)); g_fb.myMp = fbHex(tk); break;
	case 'U': g_fb.active = 0; break;
	default: break;
	}
}
static void fbHookLog(const char* s) {
	HANDLE h = CreateFileW(L"C:\\zmffk\\fastbattle-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
	if (h != INVALID_HANDLE_VALUE) { DWORD w = 0; WriteFile(h, s, (DWORD)lstrlenA(s), &w, nullptr); CloseHandle(h); }
}
static void __cdecl fbHookEN(int fd, int result, int field) {
	if (g_fbLogEn) { char b[128]; wsprintfA(b, "EN fd=%d result=%d field=%d\r\n", fd, result, field); fbHookLog(b); }
	fbShadowEN(result, field);
	if (g_fbLogEn) return; // [FastBattleBlock] fast-battle ON: drop client EN handler -> no scene/anim, char on field
	if (g_fbTrampEN) g_fbTrampEN(fd, result, field);
}
static void __cdecl fbHookB(int fd, char* command) {
	if (g_fbLogEn && command != nullptr) {
		const int c1 = command[0] ? (unsigned char)command[0] : (int)'?'; const int c2 = command[1] ? (unsigned char)command[1] : (int)'?';
		int len = lstrlenA(command); int hl = len > 240 ? 240 : len; char head[241]; for (int i = 0; i < hl; ++i) { char c = command[i]; head[i] = (c >= 32 && c < 127) ? c : '.'; } head[hl] = 0; // [FastBattleDiag165] widen BC head to read enemy HP
		char b2[320]; wsprintfA(b2, "B fd=%d sub=%c%c len=%d head=%s\r\n", fd, c1, c2, len, head); fbHookLog(b2);
	}
	fbShadowB(command);
	if (g_fbLogEn) return; // [FastBattleBlock] fast-battle ON: drop client B handler -> no battle anim
	if (g_fbTrampB) g_fbTrampB(fd, command);
}

static BYTE* fbMakeTramp(BYTE* func, int prologLen, BYTE* backTarget) {
	BYTE* tr = reinterpret_cast<BYTE*>(VirtualAlloc(nullptr, 64u, MEM_COMMIT | MEM_RESERVE, PAGE_EXECUTE_READWRITE));
	if (tr == nullptr) return nullptr;
	for (int i = 0; i < prologLen; ++i) tr[i] = func[i];
	tr[prologLen] = 0xE9;
	*reinterpret_cast<int*>(tr + prologLen + 1) = static_cast<int>(backTarget - (tr + prologLen + 5));
	FlushInstructionCache(GetCurrentProcess(), tr, static_cast<unsigned>(prologLen) + 5u);
	return tr;
}
static bool fbPatchJmp(BYTE* func, void* hook) {
	DWORD op = 0;
	if (!VirtualProtect(func, 5u, PAGE_EXECUTE_READWRITE, &op)) return false;
	func[0] = 0xE9;
	*reinterpret_cast<int*>(func + 1) = static_cast<int>(reinterpret_cast<BYTE*>(hook) - (func + 5));
	DWORD t = 0; VirtualProtect(func, 5u, op, &t);
	FlushInstructionCache(GetCurrentProcess(), func, 5u);
	return true;
}
static void fbInstallHook(std::uintptr_t base) {
	static int s_done = 0; if (s_done) return; s_done = 1;
	{ char m[64]; wsprintfA(m, "fbInstall STEP0 enter base=%p\r\n", (void*)base); fbHookLog(m); } // [FbCrashDiag174] pinpoint early crash on fast-battle install
	BYTE* enF = reinterpret_cast<BYTE*>(base + 0x00085200u);
	BYTE* bF  = reinterpret_cast<BYTE*>(base + 0x00083BF0u);
	g_fbTrampEN = reinterpret_cast<t_fbEN>(fbMakeTramp(enF, 10, reinterpret_cast<BYTE*>(base + 0x0008520Au)));
	{ char m[64]; wsprintfA(m, "fbInstall STEP1 trampEN=%p\r\n", (void*)g_fbTrampEN); fbHookLog(m); }
	g_fbTrampB  = reinterpret_cast<t_fbB>(fbMakeTramp(bF, 10, reinterpret_cast<BYTE*>(base + 0x00083BFAu)));
	{ char m[64]; wsprintfA(m, "fbInstall STEP2 trampB=%p\r\n", (void*)g_fbTrampB); fbHookLog(m); }
	int ok = 0;
	if (g_fbTrampEN && fbPatchJmp(enF, reinterpret_cast<void*>(&fbHookEN))) ok |= 1;
	{ char m[48]; wsprintfA(m, "fbInstall STEP3 patchEN ok=%d\r\n", ok); fbHookLog(m); }
	if (g_fbTrampB  && fbPatchJmp(bF,  reinterpret_cast<void*>(&fbHookB)))  ok |= 2;
	{ char m[48]; wsprintfA(m, "fbInstall STEP4 patchB ok=%d\r\n", ok); fbHookLog(m); }
	char b[96]; wsprintfA(b, "fastbattle-hook install ok=%d enTr=%p bTr=%p\r\n", ok, (void*)g_fbTrampEN, (void*)g_fbTrampB); fbHookLog(b);
}

void processAutoLoginCommand(MonitorContext& context) noexcept
{
	if (context.channel == nullptr)
		return;
	const LONG sequence = client05_readonly::readLong(context.channel->loginCommandSequence);
	if (sequence == context.lastLoginCommandSequence)
		return;
	context.lastLoginCommandSequence = sequence;

	const LONG accountLength = client05_readonly::readLong(context.channel->loginAccountLength);
	const LONG passwordLength = client05_readonly::readLong(context.channel->loginPasswordLength);
	const LONG server = client05_readonly::readLong(context.channel->requestedServer);
	const LONG subserver = client05_readonly::readLong(context.channel->requestedSubserver);
	const LONG character = client05_readonly::readLong(context.channel->requestedCharacter);

#if !CLIENT05_AUTO_LOGIN
	rejectAutoLoginCommand(context, sequence,
		client05_readonly::AutoLoginResult::featureDisabled, accountLength, passwordLength,
		server, subserver, character);
	return;
#else
	if ((context.channel->context.requestedFeatureMask &
		client05_readonly::kAutoLoginFeatureMask) == 0u)
	{
		rejectAutoLoginCommand(context, sequence,
			client05_readonly::AutoLoginResult::featureDisabled, accountLength, passwordLength,
			server, subserver, character);
		return;
	}
	if (context.bindingValidated == nullptr ||
		!context.bindingValidated->load(std::memory_order_acquire))
	{
		rejectAutoLoginCommand(context, sequence,
			client05_readonly::AutoLoginResult::profileNotValidated, accountLength,
			passwordLength, server, subserver, character);
		return;
	}
	if (accountLength <= 0 ||
		accountLength >= static_cast<LONG>(client05_readonly::kLoginCredentialBytes) ||
		passwordLength <= 0 ||
		passwordLength >= static_cast<LONG>(client05_readonly::kLoginCredentialBytes) ||
		server < 0 || server > 25 || subserver < 0 || subserver > 25 ||
		!client05_readonly::isSupportedAutoLoginCharacter(character))
	{
		rejectAutoLoginCommand(context, sequence,
			client05_readonly::AutoLoginResult::invalidPayload, accountLength, passwordLength,
			server, subserver, character);
		return;
	}

	DWORD procNo = 0u;
	// This Client05 build is operator-verified input-ready at password proc/subproc 1/0;
	// the validateLoginField/verifyLoginField checks below authoritatively gate buffer readiness.
	if (!readClientDword(context.module, context.addresses.procNo, procNo) ||
		procNo != kProcIdPassword)
	{
		rejectAutoLoginCommand(context, sequence,
			client05_readonly::AutoLoginResult::targetNotReady, accountLength,
			passwordLength, server, subserver, character);
		return;
	}

	std::uintptr_t enableAddress = 0u;
	DWORD currentEnable = 0u;
	if (!validateLoginField(context, kNewAutoLoginEnableRva, sizeof(currentEnable)) ||
		!loginTargetAddress(
			context, kNewAutoLoginEnableRva, sizeof(currentEnable), enableAddress) ||
		!readClientDword(context.module, enableAddress, currentEnable))
	{
		rejectAutoLoginCommand(context, sequence,
			client05_readonly::AutoLoginResult::addressInvalid, accountLength,
			passwordLength, server, subserver, character);
		return;
	}
	if (currentEnable != 0u)
	{
		rejectAutoLoginCommand(context, sequence,
			client05_readonly::AutoLoginResult::busy, accountLength, passwordLength,
			server, subserver, character);
		return;
	}

	std::array<char, client05_readonly::kLoginCredentialBytes> account{};
	std::array<char, client05_readonly::kLoginCredentialBytes> password{};
	std::memcpy(account.data(), context.channel->loginAccount.data(), account.size());
	std::memcpy(password.data(), context.channel->loginPassword.data(), password.size());
	auto clearLocalCredentials = [&]() noexcept
	{
		SecureZeroMemory(account.data(), account.size());
		SecureZeroMemory(password.data(), password.size());
	};
	if (account[static_cast<std::size_t>(accountLength)] != '\0' ||
		password[static_cast<std::size_t>(passwordLength)] != '\0' ||
		std::memchr(account.data(), '\0', static_cast<std::size_t>(accountLength)) != nullptr ||
		std::memchr(password.data(), '\0', static_cast<std::size_t>(passwordLength)) != nullptr)
	{
		clearLocalCredentials();
		rejectAutoLoginCommand(context, sequence,
			client05_readonly::AutoLoginResult::invalidPayload, accountLength, passwordLength,
			server, subserver, character);
		return;
	}
	std::fill(account.begin() + accountLength, account.end(), '\0');
	std::fill(password.begin() + passwordLength, password.end(), '\0');

	const std::array<std::pair<std::uint32_t, std::size_t>, kLoginControlCount> targets{
		std::pair{ kLoginAccountBufferRva, account.size() },
		std::pair{ kLoginAccountCountRva, sizeof(BYTE) },
		std::pair{ kLoginAccountCursorRva, sizeof(BYTE) },
		std::pair{ kLoginPasswordBufferRva, password.size() },
		std::pair{ kLoginPasswordCountRva, sizeof(BYTE) },
		std::pair{ kLoginPasswordCursorRva, sizeof(BYTE) },
		std::pair{ kPcLandedGroupRva, sizeof(DWORD) },
		std::pair{ kPcLandedSubserverRva, sizeof(DWORD) },
		std::pair{ kPcLandedCharacterRva, sizeof(DWORD) },
		std::pair{ kNewAutoLoginEnableRva, sizeof(DWORD) },
	};
	for (const auto& target : targets)
	{
		if (!validateLoginField(context, target.first, target.second))
		{
			clearLocalCredentials();
			rejectAutoLoginCommand(context, sequence,
				client05_readonly::AutoLoginResult::addressInvalid, accountLength,
				passwordLength, server, subserver, character);
			return;
		}
	}

	const BYTE accountByteLength = static_cast<BYTE>(accountLength);
	const BYTE passwordByteLength = static_cast<BYTE>(passwordLength);
	const DWORD serverValue = static_cast<DWORD>(server);
	const DWORD subserverValue = static_cast<DWORD>(subserver);
	const DWORD characterValue = static_cast<DWORD>(character);
	const DWORD enabled = 1u;
	const std::array<std::tuple<std::uint32_t, const void*, std::size_t>, kLoginControlCount> writes{
		std::tuple{ kLoginAccountBufferRva, account.data(), account.size() },
		std::tuple{ kLoginAccountCountRva, &accountByteLength, sizeof(accountByteLength) },
		std::tuple{ kLoginAccountCursorRva, &accountByteLength, sizeof(accountByteLength) },
		std::tuple{ kLoginPasswordBufferRva, password.data(), password.size() },
		std::tuple{ kLoginPasswordCountRva, &passwordByteLength, sizeof(passwordByteLength) },
		std::tuple{ kLoginPasswordCursorRva, &passwordByteLength, sizeof(passwordByteLength) },
		std::tuple{ kPcLandedGroupRva, &serverValue, sizeof(serverValue) },
		std::tuple{ kPcLandedSubserverRva, &subserverValue, sizeof(subserverValue) },
		std::tuple{ kPcLandedCharacterRva, &characterValue, sizeof(characterValue) },
		std::tuple{ kNewAutoLoginEnableRva, &enabled, sizeof(enabled) },
	};

	LONG verifiedControlCount = 0L;
	for (const auto& write : writes)
	{
		const auto rva = std::get<0>(write);
		const auto* value = std::get<1>(write);
		const auto size = std::get<2>(write);
		if (!guardedWriteLoginField(context, rva, value, size))
		{
			clearLocalCredentials();
			rejectAutoLoginCommand(context, sequence,
				client05_readonly::AutoLoginResult::writeFailed, accountLength,
				passwordLength, server, subserver, character, verifiedControlCount);
			return;
		}
		if (!verifyLoginField(context, rva, value, size))
		{
			clearLocalCredentials();
			rejectAutoLoginCommand(context, sequence,
				client05_readonly::AutoLoginResult::verifyFailed, accountLength,
				passwordLength, server, subserver, character, verifiedControlCount);
			return;
		}
		++verifiedControlCount;
		InterlockedExchange(
			&context.channel->loginVerifiedControlCount, verifiedControlCount);
	}
	clearLocalCredentials();
	publishAutoLoginAck(
		context, sequence, client05_readonly::AutoLoginResult::success, verifiedControlCount);
	logAutoLoginResult(context, L"applied", sequence,
		client05_readonly::AutoLoginResult::success, accountLength, passwordLength,
		server, subserver, character, verifiedControlCount);
#endif
}

bool restoreOriginalSystemTime(
	MonitorContext& context,
	client05_readonly::RestoreReason reason) noexcept
{
	context.measurementActive = false;
	if (!context.originalCaptured)
	{
		DWORD surfaceDateAfter = context.surfaceDateBefore;
		(void)readClientDword(
			context.module, context.addresses.surfaceDate, surfaceDateAfter);
		const LONG sequence = context.activeSpeedCommandSequence != 0L
			? context.activeSpeedCommandSequence
			: context.lastSpeedCommandSequence;
		publishSpeedAck(context, sequence,
			client05_readonly::SpeedResult::restored, reason, surfaceDateAfter);
		logSpeedResult(context, L"restored_without_speed_change", sequence,
			client05_readonly::SpeedResult::restored, reason, surfaceDateAfter);
		return true;
	}

	bool restored = true;
	if (context.speedChanged)
	{
		restored = guardedWriteSystemTime(
			context.module, context.addresses.systemTime, context.originalSystemTime);
	}
	if (restored)
	{
		context.appliedSystemTime = context.originalSystemTime;
		context.speedChanged = false;
	}

	DWORD surfaceDateAfter = context.surfaceDateBefore;
	(void)readClientDword(
		context.module, context.addresses.surfaceDate, surfaceDateAfter);
	const auto result = restored
		? client05_readonly::SpeedResult::restored
		: client05_readonly::SpeedResult::writeFailed;
	const LONG sequence = context.activeSpeedCommandSequence != 0L
		? context.activeSpeedCommandSequence
		: context.lastSpeedCommandSequence;
	publishSpeedAck(context, sequence, result, reason, surfaceDateAfter);
	logSpeedResult(context, restored ? L"restored" : L"restore_failed",
		sequence, result, reason, surfaceDateAfter);
	return restored;
}

void rejectSpeedCommand(
	MonitorContext& context,
	LONG sequence,
	client05_readonly::SpeedResult result) noexcept
{
	publishSpeedAck(context, sequence, result,
		client05_readonly::RestoreReason::none, context.surfaceDateBefore);
	logSpeedResult(context, L"rejected", sequence, result,
		client05_readonly::RestoreReason::none, context.surfaceDateBefore);
}

void processSpeedCommand(MonitorContext& context) noexcept
{
	if (context.channel == nullptr)
		return;
	const LONG sequence = client05_readonly::readLong(context.channel->speedCommandSequence);
	if (sequence == context.lastSpeedCommandSequence)
		return;
	if (context.measurementActive)
		return;
	context.lastSpeedCommandSequence = sequence;

#if !CLIENT05_SPEED_CONTROL
	rejectSpeedCommand(context, sequence, client05_readonly::SpeedResult::featureDisabled);
	return;
#else
	if ((context.channel->context.requestedFeatureMask &
		client05_readonly::kSpeedControlFeatureMask) == 0u)
	{
		rejectSpeedCommand(context, sequence, client05_readonly::SpeedResult::featureDisabled);
		return;
	}
	const auto mode = static_cast<client05_readonly::SpeedMode>(
		client05_readonly::readLong(context.channel->requestedSpeedMode));
	context.activeSpeedMode = mode;
	context.activeSpeedCommandSequence = sequence;
	if (!client05_readonly::isSupportedSpeedMode(mode))
	{
		rejectSpeedCommand(context, sequence, client05_readonly::SpeedResult::unsupportedMode);
		return;
	}

	if (!context.originalCaptured)
	{
		DWORD original = 0u;
		if (!readClientDword(context.module, context.addresses.systemTime, original))
		{
			rejectSpeedCommand(context, sequence, client05_readonly::SpeedResult::readFailed);
			return;
		}
		if (original < 1u || original > 100u)
		{
			context.originalSystemTime = original;
			rejectSpeedCommand(
				context, sequence, client05_readonly::SpeedResult::originalOutOfRange);
			return;
		}
		context.originalSystemTime = original;
		context.appliedSystemTime = original;
		context.originalCaptured = true;
	}

	std::uint32_t targetValue = 0u;
	if (!client05_readonly::systemTimeForMode(mode, context.originalSystemTime, targetValue))
	{
		rejectSpeedCommand(context, sequence, client05_readonly::SpeedResult::unsupportedMode);
		return;
	}
	const DWORD target = static_cast<DWORD>(targetValue);
	if (!readClientDword(context.module, context.addresses.surfaceDate, context.surfaceDateBefore))
	{
		rejectSpeedCommand(context, sequence, client05_readonly::SpeedResult::readFailed);
		return;
	}

	DWORD current = 0u;
	if (!readClientDword(context.module, context.addresses.systemTime, current))
	{
		rejectSpeedCommand(context, sequence, client05_readonly::SpeedResult::readFailed);
		return;
	}
	if (current != target &&
		!guardedWriteSystemTime(context.module, context.addresses.systemTime, target))
	{
		rejectSpeedCommand(context, sequence, client05_readonly::SpeedResult::writeFailed);
		return;
	}

	context.appliedSystemTime = target;
	context.speedChanged = target != context.originalSystemTime;
	context.measurementDeadline = GetTickCount64() + kSpeedMeasurementMilliseconds;
	context.measurementActive = true;
	InterlockedExchange(&context.channel->appliedSystemTime, static_cast<LONG>(target));
	InterlockedExchange(&context.channel->originalSystemTime,
		static_cast<LONG>(context.originalSystemTime));
	InterlockedExchange(&context.channel->surfaceDateBefore,
		static_cast<LONG>(context.surfaceDateBefore));
	InterlockedExchange(&context.channel->surfaceDateAfter,
		static_cast<LONG>(context.surfaceDateBefore));
	InterlockedExchange(&context.channel->restoreReason,
		static_cast<LONG>(mode == client05_readonly::SpeedMode::normal
			? client05_readonly::RestoreReason::normalMode
			: client05_readonly::RestoreReason::none));
	logSpeedResult(context, L"applied", sequence, client05_readonly::SpeedResult::pending,
		mode == client05_readonly::SpeedMode::normal
			? client05_readonly::RestoreReason::normalMode
			: client05_readonly::RestoreReason::none,
		context.surfaceDateBefore);
#endif
}

bool completeSpeedMeasurement(MonitorContext& context) noexcept
{
	if (!context.measurementActive || GetTickCount64() < context.measurementDeadline)
		return true;
	DWORD surfaceDateAfter = 0u;
	if (!readClientDword(context.module, context.addresses.surfaceDate, surfaceDateAfter))
	{
		context.measurementActive = false;
		publishSpeedAck(context, context.activeSpeedCommandSequence,
			client05_readonly::SpeedResult::measurementFailed,
			client05_readonly::RestoreReason::none, context.surfaceDateBefore);
		return false;
	}
	context.measurementActive = false;
	const auto reason = context.activeSpeedMode == client05_readonly::SpeedMode::normal
		? client05_readonly::RestoreReason::normalMode
		: client05_readonly::RestoreReason::none;
	publishSpeedAck(context, context.activeSpeedCommandSequence,
		client05_readonly::SpeedResult::success, reason, surfaceDateAfter);
	logSpeedResult(context, L"measured", context.activeSpeedCommandSequence,
		client05_readonly::SpeedResult::success, reason, surfaceDateAfter);
	return true;
}

void disableOnFailure(MonitorContext& context, const wchar_t* reason, const wchar_t* field)
{
	(void)restoreOriginalSystemTime(
		context, client05_readonly::RestoreReason::channelError);
	context.bindingValidated->store(false, std::memory_order_release);
	if (context.channel != nullptr)
		InterlockedExchange(&context.channel->initializationFailed, TRUE);
	std::wostringstream line;
	line << L"[" << timestamp() << L"] [disabled] " << reason;
	if (field != nullptr)
		line << L"; field=" << field;
	line << L". SASH disabled; game client left running.";
	appendUtf8Line(context.logPath, line.str());
}

unsigned __stdcall monitorThread(void* parameter)
{
	std::unique_ptr<MonitorContext> context(static_cast<MonitorContext*>(parameter));
	context->lastSpeedCommandSequence = context->channel == nullptr
		? 0L
		: client05_readonly::readLong(context->channel->speedCommandSequence);
	context->lastLoginCommandSequence = context->channel == nullptr
		? 0L
		: client05_readonly::readLong(context->channel->loginCommandSequence);
	Snapshot initial{};
	const wchar_t* failedField = nullptr;
	const wchar_t* lastFailedField = nullptr;
	const ULONGLONG snapshotReadyDeadline = GetTickCount64() +
		kClient05SnapshotReadyBudgetMilliseconds;
	for (;;)
	{
		failedField = nullptr;
		if (readSnapshot(context->module, context->addresses, initial, nullptr, failedField) &&
			isSnapshotSane(initial, failedField))
		{
			break;
		}
		lastFailedField = failedField;

		const auto requestedStop = static_cast<client05_readonly::RestoreReason>(
			context->stopReason == nullptr
				? static_cast<int>(client05_readonly::RestoreReason::none)
				: context->stopReason->load(std::memory_order_acquire));
		if (requestedStop != client05_readonly::RestoreReason::none ||
			!context->bindingValidated->load(std::memory_order_acquire) ||
			context->ownerProcess == nullptr ||
			WaitForSingleObject(context->ownerProcess, 0u) != WAIT_TIMEOUT ||
			GetTickCount64() >= snapshotReadyDeadline)
		{
			disableOnFailure(*context, L"first sane snapshot not ready", lastFailedField);
			return 0u;
		}
		Sleep(kClient05SnapshotReadyRetryMilliseconds);
	}
	logSnapshot(*context, L"login_before", initial);
	if (context->channel != nullptr)
		client05_readonly::publishSnapshot(*context->channel, initial);
	Snapshot previous = initial;

	bool serverSelected = false;
	bool fieldEntered = false;
	bool moved = false;
	bool battleEntered = false;
	Snapshot fieldSnapshot{};
	for (;;)
	{
		{ static int s_bwStarted = 0; if (!s_bwStarted) { s_bwStarted = 1; HANDLE bwth = CreateThread(nullptr, 0, blackWatchProc, nullptr, 0, nullptr); if (bwth != nullptr) { CloseHandle(bwth); } } }
		Sleep((client05_readonly::kSpeedControlCompiled ||
			client05_readonly::kAutoLoginCompiled)
			? kSpeedPollMilliseconds
			: kReadOnlyPollMilliseconds);
		const auto requestedStop = static_cast<client05_readonly::RestoreReason>(
			context->stopReason == nullptr
				? static_cast<int>(client05_readonly::RestoreReason::none)
				: context->stopReason->load(std::memory_order_acquire));
		if (requestedStop != client05_readonly::RestoreReason::none)
		{
			(void)restoreOriginalSystemTime(*context, requestedStop);
			return 0u;
		}
		if (!context->bindingValidated->load(std::memory_order_acquire))
		{
			(void)restoreOriginalSystemTime(
				*context, client05_readonly::RestoreReason::featureDisabled);
			return 0u;
		}
		if (context->channel == nullptr ||
			client05_readonly::readLong(context->channel->ipcChannelOpen) == FALSE)
		{
			(void)restoreOriginalSystemTime(
				*context, client05_readonly::RestoreReason::sessionCleanup);
			return 0u;
		}
		if (context->ownerProcess == nullptr ||
			WaitForSingleObject(context->ownerProcess, 0u) != WAIT_TIMEOUT)
		{
			(void)restoreOriginalSystemTime(
				*context, client05_readonly::RestoreReason::ownerExited);
			return 0u;
		}
		if (client05_readonly::validateContext(
			context->channel->context, GetCurrentProcessId()) !=
			client05_readonly::ContextFailure::none)
		{
			const HWND parent = reinterpret_cast<HWND>(static_cast<std::uintptr_t>(
				context->channel->context.parentHWnd));
			(void)restoreOriginalSystemTime(*context,
				parent == nullptr || IsWindow(parent) == FALSE
					? client05_readonly::RestoreReason::sashShutdown
					: client05_readonly::RestoreReason::channelError);
			return 0u;
		}

		// [FastEncSendMsgTrigger] monitor drives timing; SendMessage hands off to the MAIN thread (feWndProc).
			{
			static int s_feCnt = 0; static DWORD s_feLastLog = 0u; static int s_feWasOn = 0;
			if (context->channel != nullptr && context->channel->fastAutoWalkRequested == 1)
			{
				if (g_feHwnd == nullptr)
				{
					g_fePid = GetCurrentProcessId();
					EnumWindows(feFindWnd, 0);
					if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); }
				}
				if (!s_feWasOn) { s_feWasOn = 1; HANDLE h0 = CreateFileW(L"C:\\zmffk\\fastautowalk-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (h0 != INVALID_HANDLE_VALUE) { char b0[128]; int n0 = wsprintfA(b0, "fastenc(sendmsg) ENABLED hwnd=%p (pure in-place gcgc, no origin)\r\n", (void*)g_feHwnd); DWORD w0 = 0; WriteFile(h0, b0, (DWORD)n0, &w0, nullptr); CloseHandle(h0); } }
				const int feBat = *(volatile int*)0x0064F83Cu;
				if (g_feHwnd != nullptr && feBat == 0)
				{
					// fire EVERY monitor tick (~50ms); feWndProc sends ONE "gcgc" per tick (~20/s), no burst (drift fix)
					DWORD_PTR feRes = 0u; LRESULT feOk = 1; { static DWORD s_feWt = 0u; const DWORD feWtNow = GetTickCount(); if (s_feWt == 0u || (feWtNow - s_feWt) >= ((DWORD)g_walkDelay + 1u)) { s_feWt = feWtNow; feOk = SendMessageTimeoutW(g_feHwnd, kFeSendMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &feRes); } }
					++s_feCnt;
					const DWORD feNow = GetTickCount();
					if (s_feLastLog == 0u || (feNow - s_feLastLog) >= 1000u) { s_feLastLog = feNow; HANDLE feh = CreateFileW(L"C:\\zmffk\\fastautowalk-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (feh != INVALID_HANDLE_VALUE) { const int fecx = *(volatile int*)0x0BCDE0D8u; const int fecy = *(volatile int*)0x0BCDE0DCu; char feb[220]; int fen = wsprintfA(feb, "fastenc(sendmsg) sent cnt=%d smto=%d res=%d battling=%d pos=(%d,%d) (1/tick)\r\n", s_feCnt, (int)(feOk != 0), (int)feRes, feBat, fecx, fecy); DWORD few = 0; WriteFile(feh, feb, (DWORD)fen, &few, nullptr); CloseHandle(feh); } }
				}
			}
			else { s_feWasOn = 0; }
			}
			// [AutoEscapeSendMsgTrigger] auto-escape (自動逃跑) — monitor drives; SendMessage -> MAIN thread feWndProc -> lssproto_B_send("E").
			if (context->channel != nullptr && context->channel->autoEscapeRequested == 1)
			{
				static int s_aeCnt = 0; static DWORD s_aeLastLog = 0u; static DWORD s_aeLastSend = 0u; static int s_aeWasOn = 0;
				if (g_feHwnd == nullptr)
				{
					g_fePid = GetCurrentProcessId();
					EnumWindows(feFindWnd, 0);
					if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); }
				}
				if (!s_aeWasOn) { s_aeWasOn = 1; HANDLE h0 = CreateFileW(L"C:\\zmffk\\autoescape-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (h0 != INVALID_HANDLE_VALUE) { char b0[160]; int n0 = wsprintfA(b0, "autoescape ENABLED hwnd=%p old=%p pid=%u\r\n", (void*)g_feHwnd, (void*)g_feOldWndProc, g_fePid); DWORD w0 = 0; WriteFile(h0, b0, (DWORD)n0, &w0, nullptr); CloseHandle(h0); } }
				const int aeBat = *(volatile int*)0x0064F83Cu;
				const int aeNoEsc = *(volatile int*)0x005A8080u;
				const DWORD aeNow = GetTickCount();
				// fire EVERY monitor tick (~50ms) like auto-battle — feWndProc kEscapeMsg gates on my turn (BattleAnimFlag)+debounce.
					// old 600ms cadence missed the brief my-turn window once the menu is code-patched away (fast advance).
					if (0 && g_feHwnd != nullptr && aeBat != 0 && aeNoEsc == 0) /* disabled: autoescape routed via kBattleActMsg (char+pet) */
				{
					DWORD_PTR aeRes = 0u; LRESULT aeOk = SendMessageTimeoutW(g_feHwnd, kEscapeMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &aeRes);
					s_aeLastSend = aeNow; ++s_aeCnt;
					if (s_aeLastLog == 0u || (aeNow - s_aeLastLog) >= 1000u) { s_aeLastLog = aeNow; HANDLE aeh = CreateFileW(L"C:\\zmffk\\autoescape-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (aeh != INVALID_HANDLE_VALUE) { char aeb[200]; int aen = wsprintfA(aeb, "autoescape sent cnt=%d smto=%d res=%d battling=%d noesc=%d\r\n", s_aeCnt, (int)(aeOk != 0), (int)aeRes, aeBat, aeNoEsc); DWORD aew = 0; WriteFile(aeh, aeb, (DWORD)aen, &aew, nullptr); CloseHandle(aeh); } }
				}
			}
			// [BattleActSendMsgTrigger] auto-battle (自動戰鬥) — monitor copies channel settings into file-scope globals
// then SendMessage hands off to the MAIN thread (feWndProc kBattleActMsg) which runs lssproto_B_send.
            // [BattleMenuSuppressPatch] sa_8001-style code patch (toggled with auto-battle on/off):
            //   0x41D56E jne(75 0C)->NOP(90 90): skip BattleMenuProc entirely (no menu, no menu-state
            //     machine delay = sa_8001 fast). Client falls into the AI branch (CloseInfoWnd+AI_ChooseAction).
            //   AI_ChooseAction 3 B-send sites (0x41258B/0x412F1D/0x4130D4) E8..->90x5: neutralize the
            //     client AI's own sends (avoid double-send). Its `inc SubProcNo`(0x413190) advance is KEPT,
            //     so the turn still advances instantly. WE send per battle tab from feWndProc.
            {
                static int s_bmpApplied = -1;
                // [수동모드 자동도주 수정] 런처는 배틀 자동화(자동전투 OR 자동도주) 시 WM_EnableBattleDialog로
                // 메뉴 패널을 억제한다. 자동도주 단독일 때도 메뉴를 억제해야 수동모드에서 BattleMenuProc 대기에
                // 갇히지 않고 no-menu(AI 분기) 경로로 진행 -> "E" 송신이 명령창에 정확히 먹는다. (AI 모드와 동일 동작.)
                const int bmpWant = (context->channel != nullptr && (context->channel->autoBattleRequested == 1 || context->channel->autoEscapeRequested == 1 || context->channel->battleFallEscapeRequested == 1)) ? 1 : 0;
                if (bmpWant != s_bmpApplied)
                {
                    const DWORD bmpAddr[4] = { 0x0041D56Eu, 0x0041258Bu, 0x00412F1Du, 0x004130D4u };
                    const SIZE_T bmpLen[4] = { 2u, 5u, 5u, 5u };
                    const BYTE bmpOrig[4][5] = { {0x75,0x0C,0,0,0}, {0xE8,0x10,0x26,0x0A,0x00}, {0xE8,0x7E,0x1C,0x0A,0x00}, {0xE8,0xC7,0x1A,0x0A,0x00} };
                    const BYTE bmpNop[4][5]  = { {0x90,0x90,0,0,0}, {0x90,0x90,0x90,0x90,0x90}, {0x90,0x90,0x90,0x90,0x90}, {0x90,0x90,0x90,0x90,0x90} };
                    int bmpOk = 0;
                    for (int bpi = 0; bpi < 4; ++bpi)
                    {
                        DWORD bmpProt = 0;
                        if (VirtualProtect(reinterpret_cast<LPVOID>(bmpAddr[bpi]), bmpLen[bpi], PAGE_EXECUTE_READWRITE, &bmpProt))
                        {
                            const BYTE* bmpSrc = bmpWant ? bmpNop[bpi] : bmpOrig[bpi];
                            for (SIZE_T bpj = 0; bpj < bmpLen[bpi]; ++bpj) reinterpret_cast<volatile BYTE*>(bmpAddr[bpi])[bpj] = bmpSrc[bpj];
                            DWORD bmpTmp = 0; VirtualProtect(reinterpret_cast<LPVOID>(bmpAddr[bpi]), bmpLen[bpi], bmpProt, &bmpTmp);
                            FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<LPCVOID>(bmpAddr[bpi]), bmpLen[bpi]);
                            ++bmpOk;
                        }
                    }
                    s_bmpApplied = bmpWant;
                    HANDLE bmph = CreateFileW(L"C:\\zmffk\\autobattle-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
                    if (bmph != INVALID_HANDLE_VALUE) { char bmpb[200]; int bmpn = wsprintfA(bmpb, "battlemenu-suppress want=%d patched=%d/4 (ab=%d ae=%d)\r\n", bmpWant, bmpOk, (context->channel != nullptr ? (int)context->channel->autoBattleRequested : -9), (context->channel != nullptr ? (int)context->channel->autoEscapeRequested : -9)); DWORD bmpw = 0; WriteFile(bmph, bmpb, (DWORD)bmpn, &bmpw, nullptr); CloseHandle(bmph); }
                }
            }
            if (context->channel != nullptr && (context->channel->autoBattleRequested == 1 || context->channel->autoEscapeRequested == 1 || context->channel->battleFallEscapeRequested == 1))
            {
                static int s_baCnt = 0; static DWORD s_baLastLog = 0u; static DWORD s_baLastSend = 0u; static int s_baWasOn = 0;
                if (g_feHwnd == nullptr)
                {
                    g_fePid = GetCurrentProcessId();
                    EnumWindows(feFindWnd, 0);
                    if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); }
                }
                InterlockedExchange(&g_baCharType, context->channel->battleCharActionType);
                InterlockedExchange(&g_baCharTarget, context->channel->battleCharActionTarget);
                InterlockedExchange(&g_baPetType, context->channel->battlePetActionType);
                InterlockedExchange(&g_baPetTarget, context->channel->battlePetActionTarget);
                InterlockedExchange(&g_baCharEnemy, context->channel->battleCharNormalEnemy);
                InterlockedExchange(&g_baCharLevel, context->channel->battleCharNormalLevel);
                InterlockedExchange(&g_baCRRound, context->channel->battleCharRoundRound);
                InterlockedExchange(&g_baCREnemy, context->channel->battleCharRoundEnemy);
                InterlockedExchange(&g_baCRLevel, context->channel->battleCharRoundLevel);
                InterlockedExchange(&g_baCRType, context->channel->battleCharRoundType);
                InterlockedExchange(&g_baCRTarget, context->channel->battleCharRoundTarget);
                InterlockedExchange(&g_baCCEnable, context->channel->battleCharCrossEnable);
                InterlockedExchange(&g_baCCRound, context->channel->battleCharCrossRound);
                InterlockedExchange(&g_baCCType, context->channel->battleCharCrossType);
                InterlockedExchange(&g_baCCTarget, context->channel->battleCharCrossTarget);
                InterlockedExchange(&g_baDelay, context->channel->battleActionDelay);
                InterlockedExchange(&g_baPRRound, context->channel->battlePetRoundRound);
                InterlockedExchange(&g_baPREnemy, context->channel->battlePetRoundEnemy);
                InterlockedExchange(&g_baPRLevel, context->channel->battlePetRoundLevel);
                InterlockedExchange(&g_baPRType, context->channel->battlePetRoundType);
                InterlockedExchange(&g_baPRTarget, context->channel->battlePetRoundTarget);
                InterlockedExchange(&g_baPCEnable, context->channel->battlePetCrossEnable);
                InterlockedExchange(&g_baPCRound, context->channel->battlePetCrossRound);
                InterlockedExchange(&g_baPCType, context->channel->battlePetCrossType);
                InterlockedExchange(&g_baPCTarget, context->channel->battlePetCrossTarget);
                InterlockedExchange(&g_baMHEnable, context->channel->battleMagicHealEnable);
                InterlockedExchange(&g_baMHTarget, context->channel->battleMagicHealTarget);
                InterlockedExchange(&g_baMHChar, context->channel->battleMagicHealChar);
                InterlockedExchange(&g_baMHPet, context->channel->battleMagicHealPet);
                InterlockedExchange(&g_baMHAllie, context->channel->battleMagicHealAllie);
                InterlockedExchange(&g_baMHMagic, context->channel->battleMagicHealMagic);
                InterlockedExchange(&g_baSkillMpEn, context->channel->battleSkillMpEnable);
                InterlockedExchange(&g_baSkillMpVal, context->channel->battleSkillMpValue);
                InterlockedExchange(&g_baItemMpEn, context->channel->battleItemHealMpEnable);
                InterlockedExchange(&g_baItemMpVal, context->channel->battleItemHealMpValue);
                InterlockedExchange(&g_walkDelay, context->channel->autoWalkDelay);
                InterlockedExchange(&g_baAutoEscape, context->channel->autoEscapeRequested == 1 ? 1 : 0);
                InterlockedExchange(&g_baFallEscape, context->channel->battleFallEscapeRequested == 1 ? 1 : 0);
                if (!s_baWasOn) { s_baWasOn = 1; HANDLE h0 = CreateFileW(L"C:\\zmffk\\autobattle-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (h0 != INVALID_HANDLE_VALUE) { char b0[160]; int n0 = wsprintfA(b0, "autobattle ENABLED hwnd=%p old=%p pid=%u\r\n", (void*)g_feHwnd, (void*)g_feOldWndProc, g_fePid); DWORD w0 = 0; WriteFile(h0, b0, (DWORD)n0, &w0, nullptr); CloseHandle(h0); } }
                const int baBat = *(volatile int*)0x0064F83Cu;
                if (g_feHwnd != nullptr && baBat != 0)
                {
                    const DWORD baNow = GetTickCount();
                    if (s_baLastSend == 0u || (baNow - s_baLastSend) >= 30u)
                    {
                        s_baLastSend = baNow;
                        DWORD_PTR baRes = 0u; LRESULT baOk = SendMessageTimeoutW(g_feHwnd, kBattleActMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &baRes);
                        ++s_baCnt;
                        if (s_baLastLog == 0u || (baNow - s_baLastLog) >= 1000u) { s_baLastLog = baNow; HANDLE bah = CreateFileW(L"C:\\zmffk\\autobattle-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (bah != INVALID_HANDLE_VALUE) { char bab[200]; int ban = wsprintfA(bab, "autobattle tick cnt=%d smto=%d res=%d battling=%d ctype=%d ptype=%d\r\n", s_baCnt, (int)(baOk != 0), (int)baRes, baBat, (int)g_baCharType, (int)g_baPetType); DWORD baw = 0; WriteFile(bah, bab, (DWORD)ban, &baw, nullptr); CloseHandle(bah); } }
                    }
                }
            }
                            // [NormalHealTrigger] field (non-battle) magic-heal: mirrors launcher autoHeal() MissionThread.
                // monitor copies channel -> g_nmh*, then on (field state + enable) SendMessages MAIN thread feWndProc.
                InterlockedExchange(&g_nmhEnable, context->channel->normalMagicHealEnable);
                InterlockedExchange(&g_nmhChar, context->channel->normalMagicHealChar);
                InterlockedExchange(&g_nmhMagic, context->channel->normalMagicHealMagic);
                InterlockedExchange(&g_nmhPet, context->channel->normalMagicHealPet);
                InterlockedExchange(&g_nmhAllie, context->channel->normalMagicHealAllie);
                InterlockedExchange(&g_nmhIMpEn, context->channel->normalItemHealMpEnable);
                InterlockedExchange(&g_nmhIMpVal, context->channel->normalItemHealMpValue);
                feMpDump();
                { static DWORD s_nmhMon = 0u; const DWORD mnow = GetTickCount(); if (s_nmhMon == 0u || (mnow - s_nmhMon) >= 3000u) { s_nmhMon = mnow; HANDLE mh = CreateFileW(L"C:\\zmffk\\normalheal-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr); if (mh != INVALID_HANDLE_VALUE) { char mbf[220]; int mn = wsprintfA(mbf, "nmh-monitor en=%d hwnd=%d bat=%d chan(en=%d ch=%d mg=%d)\r\n", (int)g_nmhEnable, (int)(g_feHwnd != nullptr), *(volatile int*)0x0064F83Cu, (int)context->channel->normalMagicHealEnable, (int)context->channel->normalMagicHealChar, (int)context->channel->normalMagicHealMagic); DWORD mw = 0; WriteFile(mh, mbf, (DWORD)mn, &mw, nullptr); CloseHandle(mh); } } }
                if (g_nmhEnable != 0)
                {
                    if (g_feHwnd == nullptr) { g_fePid = GetCurrentProcessId(); EnumWindows(feFindWnd, 0); if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); } }
                    const int nmhBat = *(volatile int*)0x0064F83Cu;   // BattlingFlag (0 = field / non-battle)
                    if (g_feHwnd != nullptr && nmhBat == 0)
                    {
                        static DWORD s_nmhLast = 0u;
                        const DWORD nmhNow = GetTickCount();
                        if (s_nmhLast == 0u || (nmhNow - s_nmhLast) >= 500u)   // autoHeal 500ms cadence
                        {
                            s_nmhLast = nmhNow;
                            DWORD_PTR nmhRes = 0u; SendMessageTimeoutW(g_feHwnd, kNormalHealMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &nmhRes);
                        }
                    }
                }
                {
                // [ExpResultTrigger] 전투결과창(BattleResultWndFlag@0x005A7E28) 0->비0 엣지에 exp 채팅출력 트리거.
                //   autoBattle 무관 항상 동작(수동 전투 포함). g_feHwnd 미설정 시 여기서 subclass.
                static int s_lastResWnd = 0;
                const int resWnd = *(volatile int*)0x005A7E28u;
                if (resWnd != 0 && s_lastResWnd == 0 && context->channel != nullptr && context->channel->showExpRequested != 0)
                {
                    if (g_feHwnd == nullptr) { g_fePid = GetCurrentProcessId(); EnumWindows(feFindWnd, 0); if (g_feHwnd != nullptr) { g_feOldWndProc = (WNDPROC)SetWindowLongW(g_feHwnd, GWL_WNDPROC, (LONG)feWndProc); } }
                    if (g_feHwnd != nullptr) { DWORD_PTR exRes = 0u; SendMessageTimeoutW(g_feHwnd, kExpResultMsg, 0, 0, SMTO_ABORTIFHUNG, 300u, &exRes); }
                }
                s_lastResWnd = resWnd;
            }
            processAutoLoginCommand(*context);
			// [FastBattleHook drive] install the EN/B log-hook once (needs the module base), and gate logging by
			// the launcher kFastBattleEnable flag (fastBattleRequested). Stage1 = observe packets only.
			if (context->module != nullptr)
			{
				{ static int s_fbmon = 0; if (!s_fbmon) { s_fbmon = 1; char mm[80]; wsprintfA(mm, "FBMON first-tick module=%p chan=%p\r\n", (void*)context->module, (void*)context->channel); fbHookLog(mm); } } /* [FbCrashDiag174] monitor reached fast-battle block (once) */ if (context->channel != nullptr) { InterlockedExchange(&g_fbLogEn, client05_readonly::readLong(context->channel->fastBattleRequested) == 1 ? 1 : 0); }
				if (g_fbLogEn) { static int s_fbgate = 0; if (!s_fbgate) { s_fbgate = 1; char mg[64]; wsprintfA(mg, "FBGATE install-call g_fbLogEn=1\r\n"); fbHookLog(mg); } fbInstallHook(reinterpret_cast<std::uintptr_t>(context->module)); } // [FbCrashDiag174] FBGATE marker before install. [CycleA-Gate171] install EN/B hook ONLY when fast-battle ON. Launcher's New_lssproto_EN/B_recv is a no-op passthrough when block-flag is off, so NOT installing while off is behaviorally identical to the launcher-when-off. Isolates the cycle-A crash: fast-battle OFF -> client EN/B untouched -> pure-vanilla auto-battle.
				}
			// [AutoWalkMemMove] Native auto-walk (走路遇敵) — launcher WM_Move (sadll.cpp:1223) memory port.
			// Launcher moves the char by writing goalX/goalY + moveStart=1 into the CLIENT'S OWN move vars; the
			// client's game loop then pathfinds and walks there tile-by-tile (VISIBLE). No W2 packet, no server-side
			// step execution -> the W2 base-coordinate drift cannot occur. Verified 2026-08: W2 (even fixed-origin)
			// still drifts SW on this server because the base is NOT the lever; WM_Move (client walks itself) is the
			// launcher-native move that works and was the original passing version. moveProc @0x463535..0x46354E:
			// goalX=0xBCE0CEC, goalY=0xBCE0CF0, moveStart=0xBCE0CE8; nowGx=0xBCDE0D8, nowGy=0xBCDE0DC (all .data).
			// RVAs (base 0x400000): goalX 0xB8E0CEC / goalY 0xB8E0CF0 / moveStart 0xB8E0CE8 / nowGx 0xB8DE0D8 /
			// nowGy 0xB8DE0DC. Monitor owns the back-and-forth: capture origin on enable, walk to origX+span, flip to
			// origX-span on arrival, re-assert only when idle (moveStart==0) so the client never re-pathfinds mid-walk.
			if (context->channel != nullptr && context->module != nullptr)
			{
				static LONG s_awLast = -2;
				static int s_awOrigX = 0, s_awOrigY = 0, s_awSide = 0, s_awHaveOrig = 0, s_awNeed = 0;
				const LONG awWant = client05_readonly::readLong(context->channel->autoWalkRequested);
				const std::uintptr_t awbase = reinterpret_cast<std::uintptr_t>(context->module);
				volatile int* const awNowGx = reinterpret_cast<volatile int*>(awbase + 0x00B8DE0D8u);
				volatile int* const awNowGy = reinterpret_cast<volatile int*>(awbase + 0x00B8DE0DCu);
				volatile int* const awGoalX = reinterpret_cast<volatile int*>(awbase + 0x00B8E0CECu);
				volatile int* const awGoalY = reinterpret_cast<volatile int*>(awbase + 0x00B8E0CF0u);
				volatile int* const awMoveStart = reinterpret_cast<volatile int*>(awbase + 0x00B8E0CE8u);
				// [AutoWalkOscillate] pre-blackscreen original restored: black-repro random-walk removed + config-span removed; fixed-origin oscillation origX +/- 3.
				const int awSpan = 3;
				const int awNowX = *awNowGx;
				const int awNowY = *awNowGy;
				int awWrote = 0, awTarget = 0, awMs = 0;
				if (awWant == 1)
				{
					if (!s_awHaveOrig) { s_awOrigX = awNowX; s_awOrigY = awNowY; s_awHaveOrig = 1; s_awSide = 0; s_awNeed = 1; }
					if (s_awSide == 0 && awNowX >= s_awOrigX + awSpan) { s_awSide = 1; s_awNeed = 1; }
					else if (s_awSide == 1 && awNowX <= s_awOrigX - awSpan) { s_awSide = 0; s_awNeed = 1; }
					awTarget = (s_awSide == 0) ? (s_awOrigX + awSpan) : (s_awOrigX - awSpan);
					awMs = *awMoveStart;
					if (s_awNeed || awMs == 0)
					{
						*awGoalX = awTarget;
						*awGoalY = s_awOrigY;
						*awMoveStart = 1;
						s_awNeed = 0;
						awWrote = 1;
					}
				}
				else { s_awHaveOrig = 0; s_awSide = 0; s_awNeed = 0; }
				if (awWant != s_awLast || awWrote)
				{
					s_awLast = awWant;
					HANDLE wfh = CreateFileW(L"C:\\zmffk\\autowalk-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (wfh != INVALID_HANDLE_VALUE) { char wkb[256]; int wkn = wsprintfA(wkb, "autowalk want=%d now=(%d,%d) orig=(%d,%d) side=%d target=%d ms=%d wrote=%d\r\n", (int)awWant, awNowX, awNowY, s_awOrigX, s_awOrigY, s_awSide, awTarget, awMs, awWrote); DWORD wkw = 0; WriteFile(wfh, wkb, (DWORD)wkn, &wkw, nullptr); CloseHandle(wfh); }
				}
			}
			// Native launcher pass-wall (橫衝直撞) ported to Client05. v1 patched
			// correctCharMovePoint's checkHitMap call-site (0x00421A05 je->jmp) but that
			// routine is NOT the player's walk path (verified: patch applied 74->EB per diag,
			// yet walls still blocked). The real wall test is INSIDE checkHitMap (0x0045EAE0):
			// the launcher-pattern tile check `cmp word ptr [eax*2+0xBCE0210], 1` @ 0x0045EB34
			// followed by 0x0045EB3D `jne 0x45EB2B` (tile!=1 -> return 0 = passable; tile==1
			// falls through to 0x45EB3F `mov eax,1; ret` = blocked). Forcing that jne to jmp
			// makes tile==1 also return 0 => every IN-BOUNDS tile passable = walk through
			// walls, for EVERY caller of checkHitMap (whatever the player-walk path is).
			// Out-of-bounds still blocks (separate branch). This mirrors the launcher
			// disabling its inline tile cmp. 1-byte patch (75 'jne' <-> EB 'jmp') at VA
			// 0x0045EB3D (RVA 0x0005EB3D, .text): atomic single-byte write. ON=EB, OFF=orig
			// (75). Code patch => VirtualProtect + FlushInstructionCache. -1 = untouched.
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG pwWant = client05_readonly::readLong(context->channel->passWallRequested);
				static LONG s_pwApplied = -2;
				static BYTE s_pwOrig = 0x75;
				static bool s_pwCaptured = false;
				if (pwWant >= 0 && pwWant != s_pwApplied)
				{
					const std::uintptr_t pwBase = reinterpret_cast<std::uintptr_t>(context->module);
					BYTE* const pwp = reinterpret_cast<BYTE*>(pwBase + 0x0005EB3Du);
					if (!s_pwCaptured) { s_pwOrig = *pwp; s_pwCaptured = true; }
					const BYTE pwBefore = *pwp;
					const BYTE pwTarget = (pwWant >= 1) ? (BYTE)0xEB : s_pwOrig;
					int pwOk = 0;
					DWORD pwOldProt = 0;
					if (VirtualProtect(reinterpret_cast<LPVOID>(pwp), 1u, PAGE_EXECUTE_READWRITE, &pwOldProt))
					{
						*pwp = pwTarget;
						DWORD pwTmp = 0; VirtualProtect(reinterpret_cast<LPVOID>(pwp), 1u, pwOldProt, &pwTmp);
						FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<LPCVOID>(pwp), 1u);
						pwOk = 1;
					}
					const BYTE pwAfter = *pwp;
					s_pwApplied = pwWant;
					HANDLE pwh = CreateFileW(L"C:\\zmffk\\passwall-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (pwh != INVALID_HANDLE_VALUE) { char pwb[224]; int pwn = wsprintfA(pwb, "passwall want=%d byte %02X->%02X ok=%d orig=%02X base=%p\r\n", (int)pwWant, (int)pwBefore, (int)pwAfter, pwOk, (int)s_pwOrig, (void*)pwBase); DWORD pww = 0; WriteFile(pwh, pwb, (DWORD)pwn, &pww, nullptr); CloseHandle(pwh); }
				}
			}
			// Native launcher position-lock (鎖定原地) ported to Client05. The launcher's
			// settled/safe mechanism patches the immediate of the "queue a move" store from
			// 1 to 0 (NOT the finicky jump-patch its author warned about). Client05 site:
			// moveProc (map.obj) @ 0x00463544 `mov dword ptr [0x0BCE0CE8], 1` queues a move
			// step; consumed at 0x00463616 `cmp [0x0BCE0CE8], 0`. Only the low byte of the
			// imm (01 00 00 00) changes 01<->00, so patch a single byte at VA 0x0046354A
			// (RVA 0x0006354A, .text) — atomic, no alignment/tearing concern. Lock=0x00,
			// unlock=0x01(orig). On unlock also clear the trigger global (0x0BCE0CE8, RVA
			// 0x0B8E0CE8, .data) to drop any pending step, matching the launcher's reset.
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG lmWant = client05_readonly::readLong(context->channel->lockMoveRequested);
				static LONG s_lmApplied = -2;
				static BYTE s_lmOrigImm = 0x01;
				static bool s_lmOrigCaptured = false;
				if (lmWant >= 0 && lmWant != s_lmApplied)
				{
					const std::uintptr_t lmBase = reinterpret_cast<std::uintptr_t>(context->module);
					BYTE* const lmImm = reinterpret_cast<BYTE*>(lmBase + 0x0006354Au);
					DWORD* const lmTrig = reinterpret_cast<DWORD*>(lmBase + 0x0B8E0CE8u);
					if (!s_lmOrigCaptured) { s_lmOrigImm = *lmImm; s_lmOrigCaptured = true; }
					const BYTE lmBefore = *lmImm;
					const BYTE lmTarget = (lmWant >= 1) ? (BYTE)0x00 : s_lmOrigImm;
					int lmOk = 0;
					DWORD lmOldProt = 0;
					if (VirtualProtect(reinterpret_cast<LPVOID>(lmImm), 1u, PAGE_EXECUTE_READWRITE, &lmOldProt))
					{
						*lmImm = lmTarget;
						DWORD lmTmp = 0; VirtualProtect(reinterpret_cast<LPVOID>(lmImm), 1u, lmOldProt, &lmTmp);
						FlushInstructionCache(GetCurrentProcess(), reinterpret_cast<LPCVOID>(lmImm), 1u);
						lmOk = 1;
					}
					const BYTE lmAfter = *lmImm;
					if (lmWant == 0) { *lmTrig = 0u; }
					s_lmApplied = lmWant;
					HANDLE lmh = CreateFileW(L"C:\\zmffk\\lockmove-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (lmh != INVALID_HANDLE_VALUE) { char lmb[224]; int lmn = wsprintfA(lmb, "lockmove want=%d imm %02X->%02X ok=%d orig=%02X base=%p\r\n", (int)lmWant, (int)lmBefore, (int)lmAfter, lmOk, (int)s_lmOrigImm, (void*)lmBase); DWORD lmw = 0; WriteFile(lmh, lmb, (DWORD)lmn, &lmw, nullptr); CloseHandle(lmh); }
				}
			}
			// [AIManualLogin] Force MANUAL battle mode on world-entry, the R0-correct way: neutralize ONLY the
			// client's relogin-AI auto-restore in gamemain.cpp GameMain (src line 312-313), leaving the PgUp
			// toggle (separate stores @0x4339FB / 0x433A99) fully free so the user can switch AI<->manual.
			//   (a) relogin AI-store `mov [AI(0x59DDE8)],3` @0x433459 -> imm byte @0x43345F (RVA 0x3345F) 03->00
			//       so relogin keeps AI = AI_NONE (manual) instead of AI_SELECT (AI).
			//   (b) the relogin AI-mode chat-notice call @0x433463 (RVA 0x33463, E8 rel32 -> StockChatBufferLine)
			//       NOP x5 so the AI-mode notice line no longer prints on entry.
			// One-time code patch. No continuous AI write, no AI_CheckSetting patch (those fought PgUp and the AI
			// settings window). ai-diag.log records the one-time apply result.
			if (context->module != nullptr)
			{
				const std::uintptr_t aiBase = reinterpret_cast<std::uintptr_t>(context->module);
				static bool s_aiPatched = false;
				if (!s_aiPatched)
				{
					int aiOk = 0;
					BYTE* const aiImm = reinterpret_cast<BYTE*>(aiBase + 0x0003345Fu);
					DWORD aiP1 = 0;
					if (VirtualProtect(aiImm, 1u, PAGE_EXECUTE_READWRITE, &aiP1))
					{
						if (aiImm[0] == 0x03) { aiImm[0] = 0x00; ++aiOk; }
						DWORD aiT1 = 0; VirtualProtect(aiImm, 1u, aiP1, &aiT1);
						FlushInstructionCache(GetCurrentProcess(), aiImm, 1u);
					}
					BYTE* const aiMsg = reinterpret_cast<BYTE*>(aiBase + 0x00033463u);
					DWORD aiP2 = 0;
					if (VirtualProtect(aiMsg, 5u, PAGE_EXECUTE_READWRITE, &aiP2))
					{
						if (aiMsg[0] == 0xE8) { aiMsg[0] = 0x90; aiMsg[1] = 0x90; aiMsg[2] = 0x90; aiMsg[3] = 0x90; aiMsg[4] = 0x90; ++aiOk; }
						DWORD aiT2 = 0; VirtualProtect(aiMsg, 5u, aiP2, &aiT2);
						FlushInstructionCache(GetCurrentProcess(), aiMsg, 5u);
					}
					s_aiPatched = true;
					HANDLE aif = CreateFileW(L"C:\\zmffk\\ai-diag.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (aif != INVALID_HANDLE_VALUE) { char aib[160]; int ain = wsprintfA(aib, "AImanual one-time patch ok=%d (relogin 03->00 @+3345F, msg NOPx5 @+33463); PgUp free\r\n", aiOk); DWORD aiw = 0; WriteFile(aif, aib, (DWORD)ain, &aiw, nullptr); CloseHandle(aif); }
				}
			}
			// Native launcher time-lock (鎖定時間) — FAITHFUL R0 port of WM_SetTimeLock.
			// Launcher mechanism (sadll.cpp:971 WM_SetTimeLock + New_RealTimeToSATime/New_TimeZoneProc):
			//   (1) write 5 day/night globals to the chosen period, AND
			//   (2) SKIP the two time-advance functions while locked so nothing re-advances:
			//       pRealTimeToSATime (writes SaTime) and pTimeZoneProc (zone/palette refresh).
			// Client05 .map-verified equivalents (base 0x400000):
			//   pcurrentTime->amPmAnimeTime 0x666F0C, pa->amPmAnimeGraNoIndex0 0x666F14,
			//   pb->amPmAnimeGraNoIndex1 0x666F18, pc(source)->SaTime.hour 0x6AE99C,
			//   pd(zone)->SaTimeZoneNo 0x6AE9A8; RealTimeToSATime 0x434430, TimeZoneProc 0x4344D0.
			// Freeze = ret-patch each function entry (byte[0]->0xC3). The existing per-frame
			// amPmAnimeTime recompute (0x42F82A) then reads the frozen SaTime.hour and reproduces
			// amPmAnimeTime every frame with no race (verified: (hour+832)%1024 => the 5 values).
			// state 0..4 = 下午/黃昏/午夜/早晨/中午; -1 = unlock (restore both entries).
			// Replaces the earlier single mid-computation code patch: this is the launcher's own
			// 5-global write + 2-function skip, ported identically (R0), no invention.
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG tlWant = client05_readonly::readLong(context->channel->timeLockRequested);
				static const int s_tlAmPm[5] = { 832, 64, 320, 576, 832 };   // amPmAnimeTime
				static const int s_tlIdx0[5] = { 3, 0, 1, 2, 3 };            // amPmAnimeGraNoIndex0 = amPm/256
				static const int s_tlIdx1[5] = { 0, 1, 2, 3, 0 };            // amPmAnimeGraNoIndex1 = (idx0+1)%4
				static const int s_tlHour[5] = { 0, 256, 512, 768, 1024 };   // SaTime.hour (source counter, launcher pc)
				static const int s_tlZone[5] = { 0, 1, 2, 3, 0 };            // SaTimeZoneNo (launcher pd)
				static LONG s_tlApplied = -2;
				static BYTE s_tlOrigRt = 0x55;   // RealTimeToSATime entry (push ebp)
				static BYTE s_tlOrigTz = 0x68;   // TimeZoneProc entry (push 0x6AE994)
				static bool s_tlCap = false;
				if (tlWant >= -1 && tlWant <= 4 && tlWant != s_tlApplied)
				{
					const std::uintptr_t tlBase = reinterpret_cast<std::uintptr_t>(context->module);
					BYTE* const tlRt = reinterpret_cast<BYTE*>(tlBase + 0x00034430u); // RealTimeToSATime
					BYTE* const tlTz = reinterpret_cast<BYTE*>(tlBase + 0x000344D0u); // TimeZoneProc
					if (!s_tlCap) { s_tlOrigRt = tlRt[0]; s_tlOrigTz = tlTz[0]; s_tlCap = true; }
					int tlOk = 0;
					if (tlWant >= 0 && tlWant <= 4)
					{
						const int ti = (int)tlWant;
						// (1) FIRST skip the two advance functions (ret-patch entry) so the game
						//     thread cannot re-advance SaTime between our write and the freeze.
						DWORD tlOp = 0;
						if (VirtualProtect(tlRt, 1u, PAGE_EXECUTE_READWRITE, &tlOp)) { if (tlRt[0] != 0xC3) tlRt[0] = 0xC3; DWORD tlt = 0; VirtualProtect(tlRt, 1u, tlOp, &tlt); FlushInstructionCache(GetCurrentProcess(), tlRt, 1u); tlOk |= 1; }
						if (VirtualProtect(tlTz, 1u, PAGE_EXECUTE_READWRITE, &tlOp)) { if (tlTz[0] != 0xC3) tlTz[0] = 0xC3; DWORD tlt = 0; VirtualProtect(tlTz, 1u, tlOp, &tlt); FlushInstructionCache(GetCurrentProcess(), tlTz, 1u); tlOk |= 2; }
						// (2) THEN write the 5 period globals (launcher's data-write; now race-free).
						//     amPmAnimeTime/Index0/Index1 are also reproduced every frame by the
						//     existing 0x42F82A recompute from the frozen SaTime.hour (belt+braces).
						*reinterpret_cast<volatile int*>(tlBase + 0x002AE99Cu) = s_tlHour[ti]; // SaTime.hour (source; launcher pc)
						*reinterpret_cast<volatile int*>(tlBase + 0x002AE9A8u) = s_tlZone[ti]; // SaTimeZoneNo (launcher pd)
						*reinterpret_cast<volatile int*>(tlBase + 0x00266F0Cu) = s_tlAmPm[ti]; // amPmAnimeTime (launcher pcurrentTime)
						*reinterpret_cast<volatile int*>(tlBase + 0x00266F14u) = s_tlIdx0[ti]; // amPmAnimeGraNoIndex0 (launcher pa)
						*reinterpret_cast<volatile int*>(tlBase + 0x00266F18u) = s_tlIdx1[ti]; // amPmAnimeGraNoIndex1 (launcher pb)
					}
					else
					{
						// unlock (-1): restore both entries; client resumes real-time advance next frame
						DWORD tlOp = 0;
						if (VirtualProtect(tlRt, 1u, PAGE_EXECUTE_READWRITE, &tlOp)) { tlRt[0] = s_tlOrigRt; DWORD tlt = 0; VirtualProtect(tlRt, 1u, tlOp, &tlt); FlushInstructionCache(GetCurrentProcess(), tlRt, 1u); tlOk |= 1; }
						if (VirtualProtect(tlTz, 1u, PAGE_EXECUTE_READWRITE, &tlOp)) { tlTz[0] = s_tlOrigTz; DWORD tlt = 0; VirtualProtect(tlTz, 1u, tlOp, &tlt); FlushInstructionCache(GetCurrentProcess(), tlTz, 1u); tlOk |= 2; }
					}
					s_tlApplied = tlWant;
					HANDLE tfh = CreateFileW(L"C:\\zmffk\\timelock-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (tfh != INVALID_HANDLE_VALUE) { char tlb[256]; int tln = wsprintfA(tlb, "timelock want=%d rt=%02X tz=%02X ok=%d base=%p\r\n", (int)tlWant, (int)tlRt[0], (int)tlTz[0], tlOk, (void*)tlBase); DWORD tlw = 0; WriteFile(tfh, tlb, (DWORD)tln, &tlw, nullptr); CloseHandle(tfh); }
				}
			}
			// Native launcher fast-walk (快速走路) ported to Client05. sa_8001 launcher
			// (sadll WM_EnableFastWalk) writes the client MOVE_SPEED float 4.0<->32.0.
			// Client05 equivalent = the dedicated MOVE_SPEED constant at RVA 0x0014BDB4
			// (VA 0x0054BDB4, =4.0f), referenced by 10 mulss across the 5 movement
			// functions (ptAct->vx = dx * MOVE_SPEED * rate). Unlike boost/mute globals
			// this constant lives in .rdata (read-only), so the write is guarded by
			// VirtualProtect and only performed once VirtualProtect succeeds; the page
			// protection is restored immediately afterwards. (No SEH here: this monitor
			// function has C++ objects requiring unwinding, which forbids __try/C2712;
			// the VirtualProtect gate makes a naked write safe, like the boost block.)
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG fwWant = client05_readonly::readLong(context->channel->fastWalkRequested);
				static LONG s_fwApplied = -2;
				static float s_fwOrig = 4.0f;
				static bool s_fwOrigCaptured = false;
				if (fwWant >= 0 && fwWant != s_fwApplied)
				{
					const std::uintptr_t fwBase = reinterpret_cast<std::uintptr_t>(context->module);
					float* const fwSpeed = reinterpret_cast<float*>(fwBase + 0x0014BDB4u);
					if (!s_fwOrigCaptured) { s_fwOrig = *fwSpeed; s_fwOrigCaptured = true; }
					const float fwBefore = *fwSpeed;
					const float fwTarget = (fwWant >= 1) ? 32.0f : s_fwOrig;
					int fwOk = 0;
					DWORD fwOldProt = 0;
					if (VirtualProtect(reinterpret_cast<LPVOID>(fwSpeed), sizeof(float), PAGE_EXECUTE_READWRITE, &fwOldProt))
					{
						*fwSpeed = fwTarget;
						DWORD fwTmp = 0; VirtualProtect(reinterpret_cast<LPVOID>(fwSpeed), sizeof(float), fwOldProt, &fwTmp);
						fwOk = 1;
					}
					const float fwAfter = *fwSpeed;
					s_fwApplied = fwWant;
					HANDLE fwh = CreateFileW(L"C:\\zmffk\\fastwalk-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (fwh != INVALID_HANDLE_VALUE) { char fwb[224]; int fwn = wsprintfA(fwb, "fastwalk want=%d speed %d->%d ok=%d orig=%d base=%p\r\n", (int)fwWant, (int)fwBefore, (int)fwAfter, fwOk, (int)s_fwOrig, (void*)fwBase); DWORD fww = 0; WriteFile(fwh, fwb, (DWORD)fwn, &fww, nullptr); CloseHandle(fwh); }
				}
			}
			// Landing sampler (v15): from login screen through in-world, log procNo plus the
			// client's landed group/subserver/character globals and the auto-login enable
			// global, whenever any of them changes. Reveals whether our written landed
			// character (pos) survives until the client's selectCharacter reads gChar, and
			// whether gEnable stays set through server/group/character auto-progress.
			if (context->channel != nullptr && context->module != nullptr)
			{
				DWORD lpProc = 0xFFFFFFFFu, lg = 0xFFFFFFFFu, ls = 0xFFFFFFFFu, lc = 0xFFFFFFFFu, le = 0xFFFFFFFFu;
				readClientDword(context->module, context->addresses.procNo, lpProc);
				std::uintptr_t ag = 0u, asub = 0u, ac = 0u, ae = 0u;
				if (loginTargetAddress(*context, kPcLandedGroupRva, sizeof(DWORD), ag)) readClientDword(context->module, ag, lg);
				if (loginTargetAddress(*context, kPcLandedSubserverRva, sizeof(DWORD), asub)) readClientDword(context->module, asub, ls);
				if (loginTargetAddress(*context, kPcLandedCharacterRva, sizeof(DWORD), ac)) readClientDword(context->module, ac, lc);
				if (loginTargetAddress(*context, kNewAutoLoginEnableRva, sizeof(DWORD), ae)) readClientDword(context->module, ae, le);
				DWORD lsock = 0xFFFFFFFFu, lsub = 0xFFFFFFFFu, lwt = 0xFFFFFFFFu, lbt = 0xFFFFFFFFu;
				readClientDword(context->module, context->addresses.sockfd, lsock);
				readClientDword(context->module, context->addresses.subProcNo, lsub);
				readClientDword(context->module, context->addresses.windowTypeWN, lwt);
				readClientDword(context->module, context->addresses.buttonTypeWN, lbt);
				static DWORD s_lp = 0xDEADBEEFu, s_lg = 0xDEADBEEFu, s_ls = 0xDEADBEEFu, s_lc = 0xDEADBEEFu, s_le = 0xDEADBEEFu; static DWORD s_lsock = 0xDEADBEEFu, s_lsub = 0xDEADBEEFu, s_lwt = 0xDEADBEEFu, s_lbt = 0xDEADBEEFu;
				if (lpProc != s_lp || lg != s_lg || ls != s_ls || lc != s_lc || le != s_le || lsock != s_lsock || lsub != s_lsub || lwt != s_lwt || lbt != s_lbt)
				{
					s_lp = lpProc; s_lg = lg; s_ls = ls; s_lc = lc; s_le = le; s_lsock = lsock; s_lsub = lsub; s_lwt = lwt; s_lbt = lbt;
					HANDLE lfh = CreateFileW(L"C:\\zmffk\\landing-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (lfh != INVALID_HANDLE_VALUE) { char lb[256]; int ln = wsprintfA(lb, "proc=%lu sub=%lu sock=%lu win=%lu btn=%lu group=%ld subsrv=%ld char=%ld enable=%ld\r\n", (unsigned long)lpProc, (unsigned long)lsub, (unsigned long)lsock, (unsigned long)lwt, (unsigned long)lbt, (long)lg, (long)ls, (long)lc, (long)le); DWORD lw = 0; WriteFile(lfh, lb, (DWORD)ln, &lw, nullptr); CloseHandle(lfh); }
				}
			}
			// Auto-login gating (v13): when launcher kAutoLoginEnable is OFF, keep the client's
			// self-auto-login enable global (kNewAutoLoginEnableRva = 0xBCDD800) cleared AT ALL TIMES,
			// so a logout->password-screen transition cannot self-login before we clear it.
			if (context->channel != nullptr && context->module != nullptr)
			{
				const LONG alWant = client05_readonly::readLong(context->channel->autoLoginRequested);
				const LONG rcWant = client05_readonly::readLong(context->channel->reconnectRequested);
				DWORD alProc = 0xFFFFFFFFu;
				readClientDword(context->module, context->addresses.procNo, alProc);
				std::uintptr_t alAddr = 0u;
				DWORD alBefore = 0xFFFFFFFFu;
				if (loginTargetAddress(*context, kNewAutoLoginEnableRva, sizeof(DWORD), alAddr))
					readClientDword(context->module, alAddr, alBefore);
				static LONG s_alWantLogged = -99;
				if (((alProc == 9u) || (alWant == 0 && rcWant != 1)) && alBefore != 0u && alBefore != 0xFFFFFFFFu)
				{
					const DWORD alZero = 0u;
					const bool alOk = guardedWriteLoginField(*context, kNewAutoLoginEnableRva, &alZero, sizeof(alZero));
					DWORD alAfter = 0xFFFFFFFFu;
					if (alAddr != 0u) { readClientDword(context->module, alAddr, alAfter); }
					HANDLE afc = CreateFileW(L"C:\\zmffk\\autologin-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (afc != INVALID_HANDLE_VALUE) { char cb[192]; int cn = wsprintfA(cb, "CLEAR want=%d proc=%lu enable %lu->%lu ok=%d\r\n", (int)alWant, (unsigned long)alProc, (unsigned long)alBefore, (unsigned long)alAfter, (int)alOk); DWORD cw = 0; WriteFile(afc, cb, (DWORD)cn, &cw, nullptr); CloseHandle(afc); }
				}
				if (rcWant == 1 && alProc == 11u && alBefore == 0u)
				{
					const DWORD alOne = 1u;
					const bool rcOk = guardedWriteLoginField(*context, kNewAutoLoginEnableRva, &alOne, sizeof(alOne));
					HANDLE rfc = CreateFileW(L"C:\\zmffk\\autologin-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (rfc != INVALID_HANDLE_VALUE) { char rb[160]; int rn = wsprintfA(rb, "RECONNECT proc=11 enable 0->1 ok=%d\r\n", (int)rcOk); DWORD rw = 0; WriteFile(rfc, rb, (DWORD)rn, &rw, nullptr); CloseHandle(rfc); }
				}
				if (alWant != s_alWantLogged)
				{
					s_alWantLogged = alWant;
					HANDLE afh = CreateFileW(L"C:\\zmffk\\autologin-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (afh != INVALID_HANDLE_VALUE) { char wb[160]; int wn = wsprintfA(wb, "want=%d proc=%lu enable=%lu\r\n", (int)alWant, (unsigned long)alProc, (unsigned long)alBefore); DWORD ww = 0; WriteFile(afh, wb, (DWORD)wn, &ww, nullptr); CloseHandle(afh); }
				}
			}
			// Native launcher-boost 0~14: drive SystemTime + NO_DRAW_MAX_CNT (adjacent
			// gamemain.obj globals). boost 0 = normal (SystemTime 14, NO_DRAW_MAX_CNT 2);
			// boost 1..14 = SystemTime 15-boost (down to 1), NO_DRAW_MAX_CNT 14. In-process
			// writes on the monitor thread; sticky writes verified externally (owner).
			if (context->channel != nullptr && context->module != nullptr)
			{
				static LONG s_boostApplied = -1;
				LONG level = client05_readonly::readLong(context->channel->boostRequested);
				if (level < 0) { level = 0; }
				if (level > 14) { level = 14; }
				if (level != s_boostApplied)
				{
					const std::uintptr_t bbase = reinterpret_cast<std::uintptr_t>(context->module);
					int* const sysTime = reinterpret_cast<int*>(bbase + 0x00171520u);
					int* const noDrawMax = reinterpret_cast<int*>(bbase + 0x00171518u);
					static int s_origSys = 0; static int s_origNoDraw = 0; static bool s_origCaptured = false;
					if (!s_origCaptured) { s_origSys = *sysTime; s_origNoDraw = *noDrawMax; s_origCaptured = true; }
					const int beforeSys = *sysTime; const int beforeNoDraw = *noDrawMax;
					// [F0 boost FAITHFUL] Disasm of GameMain draw loop (SA93Client 0x43393d) proves the draw-skip
					// decision is `cmp NoDrawCnt(0x571524), NO_DRAW_MAX_CNT(0x571518)` -> this IS the faithful
					// Client05 translation of sa_8001's `cmp ecx,0Eh` (launcher patched the immediate; here the
					// max-skip moved into a data global, so WRITING the global is exactly the launcher's patch).
					// It is also the SPEED knob: speed ~ steps-per-draw = NO_DRAW_MAX_CNT. Removing it (prior
					// attempt) dropped boost to ~2 -> slow. Restore launcher fidelity: SystemTime(=pSpeed 15-level)
					// AND NO_DRAW_MAX_CNT (off=orig 2, on 1..14 => 14). Black at 14 is the launcher's inherent
					// speed/draw-skip tradeoff, NOT this write; treat separately (see GameSpeedFlag resync path).
					if (level <= 0) { *sysTime = s_origSys; *noDrawMax = s_origNoDraw; }
					else { *sysTime = 15 - level; *noDrawMax = 14; }
					s_boostApplied = level;
					HANDLE bfh = CreateFileW(L"C:\\zmffk\\boost-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (bfh != INVALID_HANDLE_VALUE) { char bbuf[224]; int bn = wsprintfA(bbuf, "boost level=%d sysTime %d->%d noDrawMax %d->%d orig(%d,%d) base=%p\r\n", (int)level, beforeSys, *sysTime, beforeNoDraw, *noDrawMax, s_origSys, s_origNoDraw, (void*)bbase); DWORD bw = 0; WriteFile(bfh, bbuf, (DWORD)bn, &bw, nullptr); CloseHandle(bfh); }
				}
			}
			// (v9) Native full mute (BGM + SE): the client's own WM_EnableSound path.
			// Zero t_music_se_volume / t_music_bgm_volume and re-apply via bgm_volume_change().
			// Applied here (monitor thread) so mute works even when no SE is currently playing.
			// RVAs from SA93Client.map; base = validated client module (fixed 0x00400000).
			if (context->channel != nullptr && context->module != nullptr)
			{
				static LONG s_muteApplied = 0;
				const LONG want = (client05_readonly::readLong(context->channel->muteRequested) != FALSE) ? 1 : 0;
				if (want != s_muteApplied)
				{
					const std::uintptr_t mbase = reinterpret_cast<std::uintptr_t>(context->module);
					int* const seVol = reinterpret_cast<int*>(mbase + 0x00194108u);
					int* const bgmVol = reinterpret_cast<int*>(mbase + 0x0019410Cu);
					const auto bgmApply = reinterpret_cast<void(__cdecl*)()>(mbase + 0x000A9FA0u);
					static int s_savedSe = 15;
					static int s_savedBgm = 15;
					const int beforeSe = *seVol;
					const int beforeBgm = *bgmVol;
					if (want == 1) { s_savedSe = beforeSe; s_savedBgm = beforeBgm; *seVol = 0; *bgmVol = 0; }
					else { *seVol = s_savedSe; *bgmVol = s_savedBgm; }
					bgmApply();
					s_muteApplied = want;
					HANDLE mfh = CreateFileW(L"C:\\zmffk\\mute-diag-172.log", FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
					if (mfh != INVALID_HANDLE_VALUE) { char mbuf[192]; int mn = wsprintfA(mbuf, "mute want=%d se %d->%d bgm %d->%d base=%p\r\n", (int)want, beforeSe, *seVol, beforeBgm, *bgmVol, (void*)mbase); DWORD mw = 0; WriteFile(mfh, mbuf, (DWORD)mn, &mw, nullptr); CloseHandle(mfh); }
				}
			}
		processSpeedCommand(*context);
		if (!completeSpeedMeasurement(*context))
		{
			(void)restoreOriginalSystemTime(
				*context, client05_readonly::RestoreReason::channelError);
			return 0u;
		}

		Snapshot current{};
		if (!readSnapshot(context->module, context->addresses, current, &previous, failedField))
		{
			disableOnFailure(*context, L"VirtualQuery/read or guarded copy failed", failedField);
			return 0u;
		}
		if (!isSnapshotSane(current, failedField)) { static int g_skipLog = 0; if (g_skipLog < 30) { logSnapshot(*context, failedField, current); ++g_skipLog; } continue; }
		if (context->channel != nullptr)
		{
			client05_readonly::publishSnapshot(*context->channel, current); // per-tick live publish
			// C9 monitor-side work is validation + PostThreadMessage only; the
			// thread-specific UI callback owns the echo terminal result.
			(void)client05_control::ControlDispatcher::pollActive(*context->channel,
				GetTickCount(), static_cast<std::uint32_t>(client05_readonly::readLong(
					context->channel->snapshotSequence)), current.procNo);
		}
		previous = current;
		static int g_periodicLog = 0; if (++g_periodicLog >= 40) { g_periodicLog = 0; logSnapshot(*context, L"periodic", current); }

		if (!serverSelected && current.selectServerIndex >= 0)
		{
			serverSelected = true;
			logSnapshot(*context, L"server_selected", current);
			if (context->channel != nullptr)
				client05_readonly::publishSnapshot(*context->channel, current);
		}
		if (!fieldEntered && current.procNo == kProcGame && current.nowFloor > 0)
		{
			fieldEntered = true;
			fieldSnapshot = current;
			logSnapshot(*context, L"field_entered", current);
			if (context->channel != nullptr)
				client05_readonly::publishSnapshot(*context->channel, current);
		}
		if (fieldEntered && !moved &&
			(current.nowGx != fieldSnapshot.nowGx || current.nowGy != fieldSnapshot.nowGy))
		{
			moved = true;
			logSnapshot(*context, L"moved", current);
			if (context->channel != nullptr)
				client05_readonly::publishSnapshot(*context->channel, current);
		}
		if (!battleEntered && current.procNo == kProcBattle)
		{
			battleEntered = true;
			logSnapshot(*context, L"battle_entered", current);
			if (context->channel != nullptr)
				client05_readonly::publishSnapshot(*context->channel, current);
			appendUtf8Line(context->logPath,
				L"[complete] All five read-only runtime milestones captured.");
			if constexpr (!client05_readonly::kSpeedControlCompiled &&
				!client05_readonly::kAutoLoginCompiled && !client05_readonly::kB1Compiled)
				return 0u;
		}
	}
}

void writeValidationAndBindingLog(
	const std::wstring& path,
	const client_profile::ClientAddressProfile& profile,
	const client_profile::ValidationResult& validation,
	const client_bindings::BindingResult& binding)
{
	appendUtf8Line(path, L"--- Client 05 read-only diagnostic session ---");
	std::wostringstream profileLine;
	profileLine << L"[profile] result=" << client_profile::validationFailureText(validation.failure)
		<< L" profile=\"" << profile.profileName << L"\" exe=\"" << profile.executableName
		<< L"\" build=\"" << profile.buildIdentifier << L"\" imageBase=0x" << std::hex
		<< binding.imageBase << L" expectedSha256=" << client_profile::sha256ToHex(profile.executableSha256)
		<< L" actualSha256=" << client_profile::sha256ToHex(validation.actualSha256)
		<< L" diskImage=\"" << validation.modulePath << L"\" processImage=\""
		<< validation.processImagePath << L"\"";
	appendUtf8Line(path, profileLine.str());

	for (std::size_t index = 0u; index < binding.diagnosticCount; ++index)
	{
		const auto& diagnostic = binding.diagnostics[index];
		std::wostringstream line;
		line << L"[binding " << (index + 1u) << L"/" << binding.diagnosticCount << L"] "
			<< diagnostic.name << L" RVA=0x" << std::hex << diagnostic.rva
			<< L" VA=0x" << diagnostic.va
			<< L" section=" << diagnostic.sectionName.data()
			<< L" writableRequired=" << std::boolalpha << diagnostic.writableRequired
			<< L" alignment=" << std::dec << diagnostic.alignment << L" result="
			<< client_bindings::bindingFailureText(diagnostic.failure);
		appendUtf8Line(path, line.str());
	}
}
}

bool startReadOnlyGlobalMonitor(
	const client_profile::ClientAddressProfile& profile,
	const client_profile::ValidationResult& validation,
	const client_bindings::BindingResult& binding,
	HMODULE clientModule,
	std::atomic_bool& bindingValidated,
	std::atomic_int& stopReason,
	client05_readonly::Channel* channel) noexcept
{
	try
	{
		if (!validation.allowed() || !binding.success() || clientModule == nullptr || channel == nullptr ||
			!bindingValidated.load(std::memory_order_acquire))
		{
			return false;
		}

		auto context = std::make_unique<MonitorContext>();
		context->module = clientModule;
		context->imageSize = binding.imageSize;
		context->addresses = binding.addresses;
		context->bindingValidated = &bindingValidated;
		context->stopReason = &stopReason;
		context->channel = channel;
		context->ownerProcess = OpenProcess(SYNCHRONIZE, FALSE, channel->context.sashProcessId);
		context->logPath = makeLogPath();
		if (context->logPath.empty() || context->ownerProcess == nullptr)
			return false;
		stopReason.store(
			static_cast<int>(client05_readonly::RestoreReason::none), std::memory_order_release);

		writeValidationAndBindingLog(context->logPath, profile, validation, binding);
		const uintptr_t thread = _beginthreadex(nullptr, 0u, monitorThread, context.get(), 0u, nullptr);
		if (thread == 0u)
		{
			appendUtf8Line(context->logPath,
				L"[disabled] Could not create read-only monitor thread; game client left running.");
			bindingValidated.store(false, std::memory_order_release);
			return false;
		}
		context.release();
		CloseHandle(reinterpret_cast<HANDLE>(thread));
		return true;
	}
	catch (...)
	{
		bindingValidated.store(false, std::memory_order_release);
		return false;
	}
}
}
