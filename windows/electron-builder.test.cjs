"use strict";
const base = require("./package.json").build;
module.exports = {
  ...base,
  appId: "com.froydinger.breeze.windows.test",
  productName: "Breeze Test",
  protocols: [],
  win: { ...base.win, artifactName: "Breeze-Test-${version}-windows-${arch}.${ext}" }
};
