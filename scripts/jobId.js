const { ethers } =  require("ethers")

async function main() {
    const id = ethers.utils.toUtf8Bytes("c734c40b377544f08a7324f36bda4940");
    console.log(id)
}

main()
    .then(() => process.exit(0))
    .catch(error => {
        console.error(error);
        process.exit(1);
    });