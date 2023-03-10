// SPDX-License-Identifier: CC-BY-NC-4.0
pragma solidity 0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

import "./interfaces/IDC.sol";
import "./interfaces/IAddressRegistry.sol";
import "./interfaces/IDCManagement.sol";
import "./interfaces/IRegistrarController.sol";
import "./interfaces/IBaseRegistrar.sol";
import "./interfaces/ITLDNameWrapper.sol";

/**
    @title A domain manager contract for .country (DC -  Dot Country)
    @author John Whitton (github.com/johnwhitton), reviewed and revised by Aaron Li (github.com/polymorpher)
    @notice This contract allows the rental of domains under .country (”DC”)
    it integrates with the ENSRegistrarController and the ENS system as a whole for persisting of domain registrations.
    It is responsible for holding the revenue from these registrations for the web2 portion of the registration process,
    with the web3 registration revenue being held by the RegistrarController contract.
    An example would be as follows Alice registers alice.com and calls the register function with an amount of 10,000 ONE.
    5000 ONE would be held by the DC contract and the remaining 5000 funds would be sent to the RegistrarController using 
    the register function.
 */
contract DC is IDC, Ownable, ReentrancyGuard, Pausable {
    /// @dev AddressRegistry
    IAddressRegistry public addressRegistry;

    uint256 public gracePeriod;
    uint256 public baseRentalPrice;
    address public revenueAccount;
    IRegistrarController public registrarController;
    IBaseRegistrar public baseRegistrar;
    ITLDNameWrapper public tldNameWrapper;
    uint256 public duration;
    address public resolver;
    bool public reverseRecord;
    uint32 public fuses;
    uint64 public wrapperExpiry;
    bool public initialized;

    mapping(bytes32 => NameRecord) public nameRecords;
    string public lastRented;

    bytes32[] public keys;

    event NameRented(string indexed name, address indexed renter, uint256 price);
    event NameRenewed(string indexed name, address indexed renter, uint256 price);
    event NameReinstated(string indexed name, address indexed renter, uint256 price, address oldRenter);
    event RevenueAccountChanged(address indexed from, address indexed to);

    receive() external payable {}

    constructor(address _addressRegistry, InitConfiguration memory _initConfig) {
        setAddressRegistry(_addressRegistry);

        setBaseRentalPrice(_initConfig.baseRentalPrice);
        setDuration(_initConfig.duration);
        setGracePeriod(_initConfig.gracePeriod);

        setRevenueAccount(_initConfig.revenueAccount);
        setWrapperExpiry(_initConfig.wrapperExpiry);
        setFuses(_initConfig.fuses);

        setRegistrarController(_initConfig.registrarController);
        setBaseRegistrar(_initConfig.baseRegistrar);
        setTLDNameWrapper(_initConfig.tldNameWrapper);
        setResolver(_initConfig.resolver);
        setReverseRecord(_initConfig.reverseRecord);
    }

    function initialize(string[] calldata _names, NameRecord[] calldata _records) external onlyOwner {
        require(!initialized, "Already initialized");
        require(_names.length == _records.length, "Invalid params");

        for (uint256 i = 0; i < _records.length; i++) {
            bytes32 key = keccak256(bytes(_names[i]));
            nameRecords[key] = _records[i];
            keys.push(key);

            if (i >= 1 && bytes(nameRecords[key].prev).length == 0) {
                nameRecords[key].prev = _names[i - 1];
            }
            if (i < _records.length - 1 && bytes(nameRecords[key].next).length == 0) {
                nameRecords[key].next = _names[i + 1];
            }
        }

        lastRented = _names[_names.length - 1];
    }

    function finishInitialization() external onlyOwner {
        initialized = true;
    }

    // admin functions
    function setAddressRegistry(address _addressRegistry) public onlyOwner {
        addressRegistry = IAddressRegistry(_addressRegistry);
    }

    function setBaseRentalPrice(uint256 _baseRentalPrice) public onlyOwner {
        baseRentalPrice = _baseRentalPrice;
    }

    function setRevenueAccount(address _revenueAccount) public onlyOwner {
        emit RevenueAccountChanged(revenueAccount, _revenueAccount);
        revenueAccount = _revenueAccount;
    }

    function setRegistrarController(address _registrarController) public onlyOwner {
        registrarController = IRegistrarController(_registrarController);
    }

    function setBaseRegistrar(address _baseRegistrar) public onlyOwner {
        baseRegistrar = IBaseRegistrar(_baseRegistrar);
    }

    function setTLDNameWrapper(address _tldNameWrapper) public onlyOwner {
        tldNameWrapper = ITLDNameWrapper(_tldNameWrapper);
    }

    function setDuration(uint256 _duration) public onlyOwner {
        duration = _duration;
    }

    function setGracePeriod(uint256 _gracePeriod) public onlyOwner {
        gracePeriod = _gracePeriod;
    }

    function setResolver(address _resolver) public onlyOwner {
        resolver = _resolver;
    }

    function setReverseRecord(bool _reverseRecord) public onlyOwner {
        reverseRecord = _reverseRecord;
    }

    function setFuses(uint32 _fuses) public onlyOwner {
        fuses = _fuses;
    }

    function setWrapperExpiry(uint64 _wrapperExpiry) public onlyOwner {
        wrapperExpiry = _wrapperExpiry;
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function numRecords() external view returns (uint256) {
        return keys.length;
    }

    function getRecordKeys(uint256 start, uint256 end) external view returns (bytes32[] memory) {
        require(end > start, "Invalid range");

        bytes32[] memory slice = new bytes32[](end - start);
        for (uint256 i = start; i < end; i++) {
            slice[i - start] = keys[i];
        }

        return slice;
    }

    /**
     * @dev `available` calls RegistrarController to check if a name is available
     * @param _name The name to be checked being registered
     */
    function available(string memory _name) public view returns (bool) {
        return registrarController.available(_name);
    }

    /**
     * @dev `makeCommitment` calls RegistrarController makeCommitment with pre-populated values
     * commitment is just a keccak256 hash
     * @param name The name being registered
     * @param owner The address of the owner of the name being registered
     * @param secret A random secret passed by the client
     */
    function makeCommitment(string memory name, address owner, bytes32 secret) public view returns (bytes32) {
        bytes[] memory data;

        return
            registrarController.makeCommitment(
                name,
                owner,
                duration,
                secret,
                resolver,
                data,
                reverseRecord,
                fuses,
                wrapperExpiry
            );
    }

    /**
     * @dev `commitment` calls RegistrarController commitment and is used as a locker to ensure that only one registration for a name occurs
     * @param commitment The commitment calculated by makeCommitment
     */
    function commit(bytes32 commitment) public {
        registrarController.commit(commitment);
    }

    /**
     * @dev `getENSPrice` gets the price needed to be paid to ENS which calculated as
     * RegistrarController.rentPrice (price.base + price.premium)
     * @param name The name being registered
     */
    function getENSPrice(string memory name) public view returns (uint256) {
        IRegistrarController.Price memory price = registrarController.rentPrice(name, duration);

        return price.base + price.premium;
    }

    function getPrice(string memory name) public view returns (uint256) {
        uint256 ensPrice = getENSPrice(name);

        return ensPrice + baseRentalPrice;
    }

    /**
     * @dev `register` calls RegistrarController register and is used to register a name
     * this also takes a fee for the web2 registration which is held by DC.sol a check is made to ensure the value sent is sufficient for both fees
     * @param name The name to be registered e.g. for test.country it would be test
     * @param secret A random secret passed by the client
     */
    function register(string calldata name, bytes32 secret, address to) external payable whenNotPaused {
        require(bytes(name).length <= 128, "Name too long");
        // require(bytes(url).length <= 1024, "URL too long");

        uint256 price = getPrice(name);
        require(price == msg.value, "Insufficient payment");
        require(available(name), "Name unavailable");

        _register(name, to, secret);

        // Update Name Record and emit events
        uint256 tokenId = uint256(keccak256(bytes(name)));
        NameRecord storage nameRecord = nameRecords[bytes32(tokenId)];
        nameRecord.renter = to;
        nameRecord.lastPrice = price;
        nameRecord.rentTime = block.timestamp;
        nameRecord.expirationTime = block.timestamp + duration;

        _updateLinkedListWithNewName(nameRecord, name);

        IDCManagement(addressRegistry.dcManagement()).onRegister(name, to, nameRecords[bytes32(tokenId)]);

        emit NameRented(name, to, price);
    }

    /**
     * @dev `_register` calls RegistrarController register and is used to register a name
     * it is passed a value to cover the costs of the ens registration
     * @param name The name to be registered e.g. for test.country it would be test
     * @param owner The owner address of the name to be registered
     * @param secret A random secret passed by the client
     */
    function _register(string calldata name, address owner, bytes32 secret) internal {
        uint256 ensPrice = getENSPrice(name);
        bytes[] memory emptyData;
        registrarController.register{value: ensPrice}(
            name,
            owner,
            duration,
            secret,
            resolver,
            emptyData,
            reverseRecord,
            fuses,
            wrapperExpiry
        );
    }

    function _updateLinkedListWithNewName(NameRecord storage nameRecord, string memory name) internal {
        nameRecords[keccak256(bytes(lastRented))].next = name;
        nameRecord.prev = lastRented;
        lastRented = name;
        keys.push(keccak256(bytes(name)));
    }

    /**
     * @dev `renew` calls RegistrarController renew and is used to renew a name
     * this also takes a fee for the web2 renewal which is held by DC.sol a check is made to ensure the value sent is sufficient for both fees
     * duration is set at the contract level
     * @param name The name to be registered e.g. for test.country it would be test
     */
    function renew(string calldata name) public payable whenNotPaused {
        require(bytes(name).length <= 128, "Name too long");

        NameRecord storage nameRecord = nameRecords[keccak256(bytes(name))];
        require(nameRecord.renter != address(0), "Name is not rented");
        require(nameRecord.expirationTime + gracePeriod >= block.timestamp, "Cannot renew after grace period");

        uint256 ensPrice = getENSPrice(name);
        uint256 price = baseRentalPrice + ensPrice;
        require(price == msg.value, "Insufficient payment");

        registrarController.renew{value: ensPrice}(name, duration);

        nameRecord.lastPrice = price;
        nameRecord.expirationTime += duration;

        emit NameRenewed(name, nameRecord.renter, price);
    }

    function getReinstateCost(string calldata name) public view returns (uint256) {
        uint256 tokenId = uint256(keccak256(bytes(name)));
        NameRecord storage nameRecord = nameRecords[bytes32(tokenId)];

        uint256 expiration = baseRegistrar.nameExpires(tokenId);
        uint256 chargeableDuration = 0;
        if (nameRecord.expirationTime == 0) {
            chargeableDuration = expiration - block.timestamp;
        }
        if (expiration > nameRecord.expirationTime) {
            chargeableDuration = expiration - nameRecord.expirationTime;
        }

        uint256 charge = (((chargeableDuration * 1e18) / duration) * baseRentalPrice) / 1e18;

        return charge;
    }

    function reinstate(string calldata _name) public payable whenNotPaused {
        uint256 tokenId = uint256(keccak256(bytes(_name)));
        NameRecord storage nameRecord = nameRecords[bytes32(tokenId)];
        require(!registrarController.available(_name), "Cannot reinstate an available name in ENS");

        (address domainOwner, uint256 expiration) = getDominOwnerOnENS(_name);
        require(expiration > block.timestamp, "Name expired");

        uint256 charge = getReinstateCost(_name);
        require(msg.value == charge, "Insufficient payment");

        nameRecord.expirationTime = expiration;
        if (nameRecord.rentTime == 0) {
            nameRecord.rentTime = block.timestamp;
        }
        if (nameRecord.renter == address(0)) {
            _updateLinkedListWithNewName(nameRecord, _name);
        }

        emit NameReinstated(_name, domainOwner, charge, nameRecord.renter);

        nameRecord.renter = domainOwner;
        nameRecord.lastPrice = charge;

        IDCManagement(addressRegistry.dcManagement()).onRegister(_name, domainOwner, nameRecords[bytes32(tokenId)]);
    }

    function getDominOwnerOnENS(string memory _name) public view returns (address owner, uint256 expireAt) {
        uint256 tokenId = uint256(keccak256(bytes(_name)));
        (owner, , ) = tldNameWrapper.getData(tokenId);
        expireAt = baseRegistrar.nameExpires(tokenId);
    }

    function withdraw() external {
        require(msg.sender == owner() || msg.sender == revenueAccount, "Owner or revenue account");

        (bool success, ) = revenueAccount.call{value: address(this).balance}("");
        require(success, "Failed to withdraw");
    }
}
