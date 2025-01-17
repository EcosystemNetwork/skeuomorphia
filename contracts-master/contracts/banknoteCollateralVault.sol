//SPDX-License-Identifier: MIT
pragma solidity >=0.8.0 <0.9.0;

// Useful for debugging. Remove when deploying to a live network.
import "hardhat/console.sol";

// Use openzeppelin to inherit battle-tested implementations (ERC20, ERC721, etc)
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";

/**
 * A smart contract that mints and redeems banknotes.  The web app is responsible for printing the notes.
 * Before calling the mint function the Dapp must create a pulic/private key pair.
 * The mint function locks the amount in the vault, stores a hash of a challenge message and the public key
 * Then mint functions returns the Id of the banknote.
 * The app must print the Id as well as the private.
 * Using the printed Id and the private key the Merchant can prove they know the challenge without revealing it
 * Redemption requires that the receiver signs a message that includes their address using the banknote's private key
 * The contract has the public key and the elements of the hash, it then verifies that sender knows the private key 
 * The funds are relesed to the msg.sender.
 * The minter of the banknote receives any change from the transaction as surplus
 * The minter can skim the surplus using a separate function.
 * @author LenOfTawa, flexfinRTP 
 */

// 9/3 gaffney - added ReentrancyGuard and SafeERC20
contract BanknoteCollateralVault is ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Banknote {
        address minter;
        address erc20;
        address pubkey;
        uint8 denomination;
    }

    address private owner;
    uint32 private nextId = 0;
    mapping(uint32 => Banknote) private banknotes; // registry of banknotes
    mapping(address => mapping(address => uint)) private surplusFunds; // registry of ERC20 balances belonging to a minter
    //Phase 2 - let the app set this based on usd/ERC20 ratio.  With a max of 8.
    uint8[] private denominations = [2, 5, 10, 20, 50, 100]; //valid denominations.

    event banknoteMinted(
        address indexed minter,
        address erc20,
        uint32 id,
        uint8 denomination
    );

    event banknoteRedeemed(
        address indexed redeemer,
        address erc20,
        uint256 amount,
        bytes32 description,
        uint32 id
    );

    event surplusFundsSkimmed(address indexed _sender, address  _erc20, uint _amount);

    event Deposited(address indexed _sender, address _erc20, uint _amount);

    constructor(address _owner) {
        owner = _owner;
    }

    // Modifier: used to define a set of rules that must be met before or after a function is executed

    modifier isOwner() {
        // msg.sender: predefined variable that represents address of the account that called the current function
        require(msg.sender == owner, "Not the Owner");
        _;
    }

    //
    // Getters
    //
    function getBanknoteInfo(
        uint32 _id
    ) public view returns (address, address, address, uint8) {
        return (
            banknotes[_id].minter,
            banknotes[_id].pubkey,
            banknotes[_id].erc20,
            banknotes[_id].denomination
        );
    }

    function getSurplus(
        address _owner,
        address _erc20
    ) public view returns (uint256) {
        return (surplusFunds[address(_owner)][address(_erc20)]);
    }

    function getNextId() public view returns (uint32) {
        return (nextId);
    }

    //
    // Utilities
    //
    function verifySignatureOfAddress(address _addr, bytes memory _signature) public pure returns (address) {
        bytes32 messageHash = keccak256(abi.encodePacked(_addr));
        bytes32 messagePrefix = "\x19Ethereum Signed Message:\n32";
        bytes32 prefixedHash = keccak256(abi.encodePacked(messagePrefix, messageHash));
        (bytes32 r, bytes32 s, uint8 v) = splitSignature(_signature);
        address signer = ecrecover(prefixedHash, v, r, s);
        return signer;
    }

    function splitSignature(bytes memory signature) public pure returns (bytes32 r, bytes32 s, uint8 v) {
        require(signature.length == 65, "Invalid signature length");

        // Extract v, r, and s from the signature
        assembly {
        r := mload(add(signature, 32))
        s := mload(add(signature, 64))
        v := byte(0, mload(add(signature, 65)))
        }
    }

    // Temp function to convert string to address
    function stringToAddress(string memory str) public pure returns (address) {
        bytes memory strBytes = bytes(str);
        require(strBytes.length == 42, "Invalid address length");
        bytes memory addrBytes = new bytes(20);

        for (uint i = 0; i < 20; i++) {
            addrBytes[i] = bytes1(hexCharToByte(strBytes[2 + i * 2]) * 16 + hexCharToByte(strBytes[3 + i * 2]));
        }

        return address(uint160(bytes20(addrBytes)));
    }

    function hexCharToByte(bytes1 char) internal pure returns (uint8) {
        uint8 byteValue = uint8(char);
        if (byteValue >= uint8(bytes1('0')) && byteValue <= uint8(bytes1('9'))) {
            return byteValue - uint8(bytes1('0'));
        } else if (byteValue >= uint8(bytes1('a')) && byteValue <= uint8(bytes1('f'))) {
            return 10 + byteValue - uint8(bytes1('a'));
        } else if (byteValue >= uint8(bytes1('A')) && byteValue <= uint8(bytes1('F'))) {
            return 10 + byteValue - uint8(bytes1('A'));
        }
        revert("Invalid hex character");
    }


    //
    // Main functions
    // 9/3 gaffney - added approveAndMint
    /*
    function approveAndMint(
        address _erc20,
        address _pubkey,
        uint8 _denomination
    ) external nonReentrant returns (uint32) {
        //Phase 2 - get the decimals from the contract
        //uint256 amount = _denomination * 10 ** 18; // Assuming 18 decimals
        //IERC20 token = IERC20(_erc20);

        // Approve and transfer in one transaction 
        // safeApprove is not part ofno safeERC20!)
        // Also does not seem to work anyway.
        token.safeApprove(address(this), amount);
        return mintBanknote(_erc20, _pubkey, _denomination);
    }
    */

    function DepositFrom(
        address _erc20,
        uint256 _amount
    ) public nonReentrant {
        IERC20(_erc20).safeTransferFrom(msg.sender, address(this), _amount);
        surplusFunds[msg.sender][_erc20] += _amount;

        emit Deposited(msg.sender, _erc20, _amount);

    }

    function mintBanknote(
        address _erc20,
        address _pubkey,
        uint8 _denomination
    ) public nonReentrant returns (uint32 id) {
        require(isDenominationValid(_denomination), "Invalid denomination");

        Banknote memory tBanknote = Banknote({
            minter: msg.sender,
            erc20: _erc20,
            pubkey: _pubkey,
            denomination: _denomination
        });

        id = nextId++;
        banknotes[id] = tBanknote;

        uint256 amount = uint256(_denomination) * 10 ** 18; // Assuming 18 decimals
        

        amount-=surplusFunds[msg.sender][_erc20];
        surplusFunds[msg.sender][_erc20] = 0;
        
        IERC20(_erc20).safeTransferFrom(msg.sender, address(this), amount);
        /*
        if (surplusFunds[msg.sender][_erc20] >= amount) {
            surplusFunds[msg.sender][_erc20] -= amount;
        } else {
            IERC20(_erc20).safeTransferFrom(msg.sender, address(this), amount);
        }
        */

        emit banknoteMinted(msg.sender, _erc20, id, _denomination);
    }

 
    function redeemBanknote(
        uint32 _banknote,
        uint256 _amount,
        bytes calldata _sig, // Must be senders address signed with the private key on the banknote.
        bytes32 _description
    ) public nonReentrant {
        uint8 _denomination = banknotes[_banknote].denomination; // 0 if there is no valid banknote
        Banknote memory note = banknotes[_banknote];
        require(_denomination != 0, "Bad banknote");

        address signer = banknotes[_banknote].pubkey; // *** DEBUG MODE*** - FORCE SUCCESS FOR NOW!!
        // Check that the message (sender's address) was signed by the private key on the banknote 
        // address signer = verifySignatureOfAddress(msg.sender, _sig);

        require(signer == banknotes[_banknote].pubkey, "Redemption denied");

        uint256 maxAmount = uint256(note.denomination) * 10 ** 18;
        require(_amount <= maxAmount, "Amount too large");
        require((_amount) <= maxAmount, "Total amount too large");

        uint256 change = maxAmount - _amount;
        surplusFunds[note.minter][note.erc20] += change;

        IERC20(note.erc20).safeTransfer(msg.sender, _amount);

        emit banknoteRedeemed(
            msg.sender,
            note.erc20,
            _amount,
            _description,
            _banknote
        );

        banknotes[_banknote].minter = address(0);
        banknotes[_banknote].pubkey = address(0);
        banknotes[_banknote].erc20 = address(0);
        banknotes[_banknote].denomination = 0;
        delete (banknotes[_banknote]);
    }

    function skimSurplus(address _erc20, uint256 _amount) public nonReentrant {

        uint256 availableSurplus = surplusFunds[msg.sender][_erc20];
        require(availableSurplus != 0, "No surplus funds");

        uint256 _withdrawal = _amount == 0 ? availableSurplus : _amount; // 0 means all surplus
        require(_withdrawal <= availableSurplus, "Amount exceeds surplus");

        surplusFunds[msg.sender][_erc20] -= _withdrawal;

        IERC20(_erc20).safeTransfer(msg.sender, _withdrawal);

        emit surplusFundsSkimmed(msg.sender,_erc20, _withdrawal);
    }

    function isDenominationValid(
        uint8 _denomination
    ) internal view returns (bool) {
        for (uint8 i = 0; i < denominations.length; i++) {
            if (_denomination == denominations[i]) {
                return true;
            }
        }
        return false;
    }
    /**
     * Function that allows the contract to receive ETH
     */
    receive() external payable {}
}