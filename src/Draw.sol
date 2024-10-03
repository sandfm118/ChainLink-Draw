// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

/**
 * @title A simple Draw contract
 * @author SANDF
 *
 */
import {VRFCoordinatorV2Interface} from "@chainlink/contracts/src/v0.8/vrf/interfaces/VRFCoordinatorV2Interface.sol";
import {VRFConsumerBaseV2} from "@chainlink/contracts/src/v0.8/vrf/VRFConsumerBaseV2.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract Draw is VRFConsumerBaseV2 {
    error Draw__NotEnoghEthSent();
    error Draw__TransferFailed();
    error Draw__DrawNotOpen();
    error Draw__UpkeepNotNeeded(
        uint256 currentBalance,
        uint256 numPalyers,
        uint256 drawState
    );

    enum DrawState {
        OPEN,
        CALCULATING
    }

    uint16 private constant REQUEST_CONFIRMATIONS = 3;
    uint32 private constant NUM_WORDS = 1;

    uint256 private immutable i_entranceFee;
    uint256 private immutable i_interval;
    VRFCoordinatorV2Interface private immutable i_vrfCoordinator;
    bytes32 private immutable i_gasLane;
    uint64 private immutable i_subscriptionId;
    uint32 private immutable i_callbackGasLimit;

    address payable[] private s_players;
    uint256 private s_lastTimeStamp;
    address private s_recentWinner;
    DrawState private s_drawState;

    /**
     * Events
     */
    event EnteredDraw(address indexed player);
    event PickedWinner(address indexed winner);
    event RequestedDrawWinner(uint256 indexed requestId);

    constructor(
        uint256 entranceFee,
        uint256 interval,
        address vrfCoordinator,
        bytes32 gasLane,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) VRFConsumerBaseV2(vrfCoordinator) {
        i_entranceFee = entranceFee;
        i_interval = interval;
        s_lastTimeStamp = block.timestamp;
        i_vrfCoordinator = VRFCoordinatorV2Interface(vrfCoordinator);
        i_subscriptionId = subscriptionId;
        i_gasLane = gasLane;
        i_callbackGasLimit = callbackGasLimit;
        s_drawState = DrawState.OPEN;
    }

    function enterDraw() external payable {
        if (msg.value < i_entranceFee) {
            revert Draw__NotEnoghEthSent();
        }
        if (s_drawState != DrawState.OPEN) {
            revert Draw__DrawNotOpen();
        }
        s_players.push(payable(msg.sender));
        emit EnteredDraw(msg.sender);
    }

    //get random number and call automatically .
    function checkUpkeep(
        bytes memory
    ) public view returns (bool upkeepNeeded, bytes memory) {
        bool timeHasPassed = (block.timestamp - s_lastTimeStamp) >= i_interval;
        bool isOpen = DrawState.OPEN == s_drawState;
        bool hasBalance = address(this).balance > 0;
        bool hasPalyers = s_players.length > 0;
        upkeepNeeded = (timeHasPassed && isOpen && hasBalance && hasPalyers);
        return (upkeepNeeded, "0x0");
    }

    function performUpkeep(bytes calldata /* performData */) external {
        (bool upkeepNeeded, ) = checkUpkeep("");
        if (!upkeepNeeded) {
            revert Draw__UpkeepNotNeeded(
                address(this).balance,
                s_players.length,
                uint256(s_drawState)
            );
        }
        s_drawState = DrawState.CALCULATING;
        uint256 requestId = i_vrfCoordinator.requestRandomWords(
            i_gasLane,
            i_subscriptionId,
            REQUEST_CONFIRMATIONS,
            i_callbackGasLimit,
            NUM_WORDS
        );
        emit RequestedDrawWinner(requestId);
    }

    function fulfillRandomWords(
        uint256,
        /*requestId */ uint256[] memory randomWords
    ) internal override {
        //s_players = 10 , random =12 , 12%10 = 2 , 3622222222456345747457476765746 % 10 =6
        uint256 indexOfWinner = randomWords[0] % s_players.length;
        address payable winner = s_players[indexOfWinner];
        s_recentWinner = winner;
        s_drawState = DrawState.OPEN;
        s_players = new address payable[](0);
        s_lastTimeStamp = block.timestamp;
        emit PickedWinner(winner);
        (bool success, ) = s_recentWinner.call{value: address(this).balance}(
            ""
        );
        if (!success) {
            revert Draw__TransferFailed();
        }
    }

    /**
     * Getter Function
     */
    function getEntranceFee() external view returns (uint256) {
        return i_entranceFee;
    }

    function getDrawState() external view returns (DrawState) {
        return s_drawState;
    }

    function getPlayer(uint256 indexOfPlayer) external view returns (address) {
        return s_players[indexOfPlayer];
    }

    function getRecentWinner() external view returns (address) {
        return s_recentWinner;
    }

    function getLengthOfPlayers() external view returns (uint256) {
        return s_players.length;
    }

    function getLastTimeStamp() external view returns (uint256) {
        return s_lastTimeStamp;
    }
}
