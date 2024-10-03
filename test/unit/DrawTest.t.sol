// SPDX-License-Identifier: MIT

pragma solidity ^0.8.19;

import {DeployDraw} from "../../script/DeployDraw.s.sol";
import {Draw} from "../../src/Draw.sol";
import {Test, console} from "forge-std/Test.sol";
import {HelperConfig} from "../../script/HelperConfig.s.sol";
import {Vm} from "forge-std/Vm.sol";
import {VRFCoordinatorV2Mock} from "@chainlink/contracts/src/v0.8/mocks/VRFCoordinatorV2Mock.sol";

contract DrawTest is Test {
    event EnteredDraw(address indexed player);

    Draw draw;
    HelperConfig helperConfig;

    uint256 entranceFee;
    uint256 interval;
    address vrfCoordinator;
    bytes32 gasLane;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
    address link;

    address public PLAYER = makeAddr("player"); //feck player address
    uint256 public constant STARTING_USER_BALANCE = 10 ether;

    function setUp() external {
        DeployDraw deployer = new DeployDraw();
        (draw, helperConfig) = deployer.run();
        (
            entranceFee,
            interval,
            vrfCoordinator,
            gasLane,
            subscriptionId,
            callbackGasLimit,
            link,

        ) = helperConfig.activeNetworkConfig();
        vm.deal(PLAYER, STARTING_USER_BALANCE);
    }

    function testDrawInitializesInOpenState() public view {
        assert(draw.getDrawState() == Draw.DrawState.OPEN);
    }

    function testDrawRevertsWhenYouDontPayEnough() public {
        vm.prank(PLAYER);

        vm.expectRevert(Draw.Draw__NotEnoghEthSent.selector);
        draw.enterDraw();
    }

    function testDrawRecordsPlayerWhenTheyEnter() public {
        vm.prank(PLAYER);

        draw.enterDraw{value: entranceFee}();
        address playerRecorded = draw.getPlayer(0);
        assert(playerRecorded == PLAYER);
    }

    function testEmitEventOnEntrance() public {
        vm.prank(PLAYER);
        vm.expectEmit(true, false, false, false, address(draw));
        emit EnteredDraw(PLAYER);
        draw.enterDraw{value: entranceFee}();
    }

    function testCanEnterWhenDrawIdCalculating() public {
        vm.prank(PLAYER);
        draw.enterDraw{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1); // warp -> setd block.timestamp ;
        vm.roll(block.number + 1); // roll -> sets block.number;
        draw.performUpkeep("");

        vm.expectRevert(Draw.Draw__DrawNotOpen.selector);
        vm.prank(PLAYER);
        draw.enterDraw{value: entranceFee}();
    }

    //checkUpkeep
    function testCheckupkeepReturnsFalseIfthasNoBalance() public {
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded, ) = draw.checkUpkeep("");

        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsFalseIfDrawNotOpen() public {
        vm.prank(PLAYER);
        draw.enterDraw{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1); // warp -> setd block.timestamp ;
        vm.roll(block.number + 1); // roll -> sets block.number;
        draw.performUpkeep("");

        (bool upkeepNeeded, ) = draw.checkUpkeep("");

        assert(upkeepNeeded == false);
    }

    function testCheckUpkeepReturnsFalseIfEnoughTimeHasntPassed() public {
        vm.prank(PLAYER);
        draw.enterDraw{value: entranceFee}();

        (bool upkeepNeeded, ) = draw.checkUpkeep("");

        console.log(upkeepNeeded);
        assert(!upkeepNeeded);
    }

    function testCheckUpkeepReturnsTrueWhenParametersGood() public {
        vm.prank(PLAYER);
        draw.enterDraw{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);

        (bool upkeepNeeded, ) = draw.checkUpkeep("");

        assert(upkeepNeeded);
        console.log(upkeepNeeded);
    }

    /*//////////////////////////////////////////////////////////////
                             PERFORMUPKEEP
    //////////////////////////////////////////////////////////////*/

    function testPerfromUpkeepRevertsIfCheckUpkeepIsFalse() public {
        uint256 currentBalance = 0;
        uint256 numPlayers = 0;
        uint256 drawState = 0;

        vm.expectRevert(
            abi.encodeWithSelector(
                Draw.Draw__UpkeepNotNeeded.selector,
                currentBalance,
                numPlayers,
                drawState
            )
        );
        draw.performUpkeep("");
    }

    modifier drawEnteredAndTimePassed() {
        vm.prank(PLAYER);
        draw.enterDraw{value: entranceFee}();
        vm.warp(block.timestamp + interval + 1);
        vm.roll(block.number + 1);
        _;
    }

    function testPerfromUpkeepUpdatesDrawStateAndEmitsRequestId()
        public
        drawEnteredAndTimePassed
    {
        vm.recordLogs();
        draw.performUpkeep(""); //emit requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        Draw.DrawState rState = draw.getDrawState();

        assert(uint256(requestId) > 0);
        assert(uint256(rState) == 1);
    }

    /////////////////////////
    // fulfillRandomWords //
    ///////////////////////

    modifier skipFork() {
        if (block.chainid != 31337) {
            return;
        }
        _;
    }

    function testFulfillRandomWordsConOnlyBeCalledAfterPerformUpkeep(
        uint256 randomRequestId // fuzzing test
    ) public drawEnteredAndTimePassed skipFork {
        vm.expectRevert("nonexistent request");
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            randomRequestId,
            address(draw)
        );
    }

    function testFulfillRandomWordsPicksAWinnerResetsAndSendsMoney()
        public
        drawEnteredAndTimePassed
        skipFork
    {
        uint256 additionalEntrants = 5;
        uint256 startingIndex = 1;
        for (
            uint256 i = startingIndex;
            i < startingIndex + additionalEntrants;
            i++
        ) {
            address player = address(uint160(i));
            hoax(player, STARTING_USER_BALANCE); //sets up a prank from an address that has some ether.
            draw.enterDraw{value: entranceFee}();
        }

        uint256 prize = entranceFee * (additionalEntrants + 1);

        vm.recordLogs();
        draw.performUpkeep(""); //emit requestId
        Vm.Log[] memory entries = vm.getRecordedLogs();
        bytes32 requestId = entries[1].topics[1];

        uint256 previousTimeStamp = draw.getLastTimeStamp();

        // pretend to be chainlink vrf to get random number & pick winner.
        VRFCoordinatorV2Mock(vrfCoordinator).fulfillRandomWords(
            uint256(requestId),
            address(draw)
        );

        assert(uint256(draw.getDrawState()) == 0);
        assert(draw.getRecentWinner() != address(0));
        assert(draw.getLengthOfPlayers() == 0);
        assert(previousTimeStamp < draw.getLastTimeStamp());
        console.log(draw.getRecentWinner().balance);
        console.log(prize);
        assert(
            draw.getRecentWinner().balance ==
                STARTING_USER_BALANCE + prize - entranceFee
        );
    }
}
